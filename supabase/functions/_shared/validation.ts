import { AppError } from './errors.ts';

export function requireString(
  value: unknown,
  field: string,
  maxLength?: number,
): string {
  if (typeof value !== 'string' || value.trim().length === 0) {
    throw new AppError('invalid_payload', `${field} must be a non-empty string`, 400);
  }

  const trimmed = value.trim();
  if (maxLength && trimmed.length > maxLength) {
    throw new AppError('invalid_payload', `${field} exceeds max length`, 400);
  }

  return trimmed;
}

export function requireUuid(value: unknown, field: string): string {
  const text = requireString(value, field);
  if (!/^[0-9a-fA-F-]{36}$/.test(text)) {
    throw new AppError('invalid_payload', `${field} must be a UUID`, 400);
  }
  return text;
}

export function requireNonNegativeInt(value: unknown, field: string): number {
  if (!Number.isInteger(value) || Number(value) < 0) {
    throw new AppError('invalid_payload', `${field} must be a non-negative integer`, 400);
  }
  return Number(value);
}

export function requireObject(value: unknown, field: string): Record<string, unknown> {
  if (typeof value !== 'object' || value === null || Array.isArray(value)) {
    throw new AppError('invalid_payload', `${field} must be an object`, 400);
  }
  return value as Record<string, unknown>;
}
