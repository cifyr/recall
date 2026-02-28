import { AppError } from './errors.ts';

export type RequestContext = {
  requestId: string;
  idempotencyKey: string;
  contractVersion: string;
  deviceId: string;
  platform: 'iphone' | 'watch' | 'edge' | 'system';
  appVersion: string;
  osVersion: string;
  correlationId: string | null;
};

export function buildRequestContext(request: Request): RequestContext {
  const requestId = request.headers.get('x-request-id') ?? crypto.randomUUID();
  const idempotencyKey = request.headers.get('idempotency-key') ?? requestId;
  const contractVersion = request.headers.get('x-contract-version') ?? '1';
  const deviceId = request.headers.get('x-device-id') ?? 'unknown-device';
  const platformHeader = request.headers.get('x-platform') ?? 'iphone';
  const appVersion = request.headers.get('x-app-version') ?? 'unknown';
  const osVersion = request.headers.get('x-os-version') ?? 'unknown';
  const correlationId = request.headers.get('x-correlation-id');

  if (!['iphone', 'watch', 'edge', 'system'].includes(platformHeader)) {
    throw new AppError('invalid_platform', 'Unsupported platform header', 400);
  }

  return {
    requestId,
    idempotencyKey,
    contractVersion,
    deviceId,
    platform: platformHeader as RequestContext['platform'],
    appVersion,
    osVersion,
    correlationId,
  };
}

export async function parseJson<T>(request: Request): Promise<T> {
  try {
    return await request.json() as T;
  } catch (_error) {
    throw new AppError('invalid_payload', 'Body must be valid JSON', 400);
  }
}

export function getIpAddress(request: Request): string {
  return request.headers.get('x-forwarded-for')?.split(',')[0]?.trim() ?? 'unknown-ip';
}
