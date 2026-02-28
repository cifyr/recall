import { AppError } from './errors.ts';

type Meta = {
  request_id: string;
};

export function success(data: unknown, requestId: string, status = 200): Response {
  return Response.json(
    {
      ok: true,
      data,
      meta: {
        request_id: requestId,
      } satisfies Meta,
    },
    { status },
  );
}

export function failure(error: AppError, requestId: string): Response {
  return Response.json(
    {
      ok: false,
      error: {
        code: error.code,
        message: error.message,
        details: error.details ?? null,
      },
      meta: {
        request_id: requestId,
      } satisfies Meta,
    },
    { status: error.status },
  );
}
