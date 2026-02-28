import { asAppError, AppError } from './errors.ts';
import { failure } from './response.ts';
import { recordFunctionInvocation } from './telemetry.ts';

type HandlerResult = {
  response: Response;
  userId?: string;
  errorCode?: string | null;
  correlationId?: string | null;
};

export async function withErrorHandling(
  functionName: string,
  requestId: string,
  handler: () => Promise<HandlerResult>,
): Promise<Response> {
  const start = Date.now();
  let userId: string | undefined;
  let correlationId: string | null | undefined;
  let statusCode = 500;
  let result: 'ok' | 'error' = 'error';
  let errorCode: string | null = null;
  let errorMessage: string | null = null;

  try {
    const handled = await handler();
    userId = handled.userId;
    correlationId = handled.correlationId;
    statusCode = handled.response.status;
    result = handled.response.ok ? 'ok' : 'error';
    errorCode = handled.errorCode ?? null;
    return handled.response;
  } catch (error) {
    const appError = asAppError(error);
    statusCode = appError.status;
    errorCode = appError.code;
    errorMessage = appError.message;
    return failure(appError, requestId);
  } finally {
    await recordFunctionInvocation({
      functionName,
      userId,
      requestId,
      correlationId,
      statusCode,
      durationMs: Date.now() - start,
      result,
      errorCode,
      errorMessage,
    }).catch((invocationError) => {
      console.error('function_invocation_record_failed', invocationError);
    });
  }
}

export function assertMethod(request: Request, expected: string): void {
  if (request.method !== expected) {
    throw new AppError('method_not_allowed', `Expected ${expected}`, 405);
  }
}
