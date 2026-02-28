import { createServiceClient } from './clients.ts';
import { AppError } from './errors.ts';

export async function resolveSecretValue(options: {
  envValue?: string;
  vaultName: string;
  errorCode: string;
  errorMessage: string;
}): Promise<string> {
  if (options.envValue) {
    return options.envValue;
  }

  const serviceClient = createServiceClient();
  const { data, error } = await serviceClient
    .rpc('get_edge_secret', { p_name: options.vaultName });

  if (error || typeof data !== 'string' || data.length === 0) {
    throw new AppError(options.errorCode, options.errorMessage, 500);
  }

  return data;
}

export async function validateInternalSecret(secret: string): Promise<boolean> {
  const serviceClient = createServiceClient();
  const { data, error } = await serviceClient
    .rpc('is_valid_internal_job_secret', { p_secret: secret });

  if (error) {
    throw new AppError('missing_internal_secret', 'Internal job secret is not configured', 500);
  }

  return data === true;
}
