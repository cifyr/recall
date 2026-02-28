import { AppError } from './errors.ts';
import { createServiceClient } from './clients.ts';
import type { AuthUser } from './types.ts';
import { env } from './env.ts';
import { resolveSecretValue, validateInternalSecret } from './secrets.ts';

export async function requireUser(request: Request): Promise<AuthUser> {
  const authorization = request.headers.get('authorization') ?? request.headers.get('Authorization');
  const token = authorization?.replace(/^Bearer\s+/i, '');
  if (!token) {
    throw new AppError('unauthorized', 'Missing bearer token', 401);
  }

  const serviceClient = createServiceClient();
  const { data, error } = await serviceClient.auth.getUser(token);
  if (error || !data.user) {
    throw new AppError('unauthorized', 'Invalid bearer token', 401);
  }

  return {
    id: data.user.id,
    email: data.user.email ?? undefined,
  };
}

async function resolveInternalSecret(): Promise<string> {
  return await resolveSecretValue({
    envValue: env.internalJobSecret,
    vaultName: 'internal_job_secret',
    errorCode: 'missing_internal_secret',
    errorMessage: 'Internal job secret is not configured',
  });
}

export async function requireInternalSecret(request: Request): Promise<void> {
  const secret = request.headers.get('x-internal-job-secret');
  if (!secret) {
    throw new AppError('unauthorized', 'Missing internal authorization', 401);
  }

  if (env.internalJobSecret) {
    if (secret !== env.internalJobSecret) {
      throw new AppError('unauthorized', 'Missing internal authorization', 401);
    }
    return;
  }

  if (!(await validateInternalSecret(secret))) {
    throw new AppError('unauthorized', 'Missing internal authorization', 401);
  }
}

export async function getInternalSecretForInternalCalls(): Promise<string> {
  return await resolveInternalSecret();
}
