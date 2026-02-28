import { assertMethod, withErrorHandling } from '../_shared/http.ts';
import { buildRequestContext, getIpAddress, parseJson } from '../_shared/request.ts';
import { requireUser } from '../_shared/auth.ts';
import { requireString, requireUuid } from '../_shared/validation.ts';
import { AppError } from '../_shared/errors.ts';
import { createServiceClient } from '../_shared/clients.ts';
import { getPromptTemplate } from '../_shared/prompts.ts';
import { answerQuestion } from '../_shared/openai.ts';
import { success } from '../_shared/response.ts';
import { checkRateLimit } from '../_shared/rate-limit.ts';
import { requireOwnedSession } from '../_shared/db.ts';

Deno.serve(async (request) => {
  const context = buildRequestContext(request);

  return await withErrorHandling('ask-session', context.requestId, async () => {
    assertMethod(request, 'POST');
    const authUser = await requireUser(request);
    const body = await parseJson<Record<string, unknown>>(request);
    const sessionId = requireUuid(body.session_id, 'session_id');
    const question = requireString(body.question, 'question', 2000);
    const includeUserNotes = body.include_user_notes !== false;

    for (const [scopeType, scopeId] of [
      ['user', authUser.id],
      ['device', context.deviceId],
      ['ip', getIpAddress(request)],
    ] as const) {
      const rateLimit = await checkRateLimit(scopeType, scopeId, 'ask_session', context.requestId);
      if (!rateLimit.allowed) {
        throw new AppError('rate_limit_exceeded', 'Question rate limit exceeded', 429, {
          retry_after_seconds: rateLimit.retry_after_seconds,
        });
      }
    }

    await requireOwnedSession(sessionId, authUser.id);
    const serviceClient = createServiceClient();
    const { data: transcript, error: transcriptError } = await serviceClient
      .from('conversation_transcripts')
      .select('*')
      .eq('session_id', sessionId)
      .eq('user_id', authUser.id)
      .maybeSingle();
    if (transcriptError) {
      throw new AppError('transcript_missing', transcriptError.message, 500);
    }
    if (!transcript) {
      throw new AppError('transcript_missing', 'Transcript missing for session', 404);
    }

    const { data: summaries, error: summariesError } = await serviceClient
      .from('conversation_summaries')
      .select('*')
      .eq('session_id', sessionId)
      .eq('user_id', authUser.id)
      .order('created_at', { ascending: true });
    if (summariesError) {
      throw new AppError('summary_lookup_failed', summariesError.message, 500);
    }

    const { data: notes } = await serviceClient
      .from('conversation_notes')
      .select('note_text')
      .eq('session_id', sessionId)
      .eq('user_id', authUser.id)
      .maybeSingle();

    const prompt = await getPromptTemplate('qa_grounded_default');
    const { data: questionRow, error: questionInsertError } = await serviceClient
      .from('conversation_questions')
      .insert({
        session_id: sessionId,
        user_id: authUser.id,
        question,
        status: 'pending',
        request_id: context.requestId,
        correlation_id: context.correlationId,
      })
      .select('*')
      .single();
    if (questionInsertError || !questionRow) {
      throw new AppError('qa_upstream_error', questionInsertError?.message ?? 'Unable to create question row', 500);
    }

    try {
      const startedAt = Date.now();
      const answer = await answerQuestion({
        transcript: transcript.transcript_text,
        summaries: (summaries ?? []).map((summary) => `${summary.summary_prompt_name}: ${summary.summary_text}`).join('\n\n'),
        notes: includeUserNotes ? (notes?.note_text ?? '') : '',
        question,
        prompt: prompt.template_text,
      });

      const { error: updateError } = await serviceClient
        .from('conversation_questions')
        .update({
          answer: answer.text,
          status: 'answered',
          model: answer.model,
          tokens_in: answer.usage?.input_tokens ?? null,
          tokens_out: answer.usage?.output_tokens ?? null,
          latency_ms: Date.now() - startedAt,
          answered_at: new Date().toISOString(),
        })
        .eq('id', questionRow.id);
      if (updateError) {
        throw new AppError('qa_upstream_error', updateError.message, 500);
      }

      await serviceClient.from('ai_model_calls').insert({
        user_id: authUser.id,
        session_id: sessionId,
        question_id: questionRow.id,
        stage: 'ask',
        provider: 'openai',
        model: answer.model,
        prompt_template_name: prompt.name,
        prompt_template_version: prompt.version,
        tokens_in: answer.usage?.input_tokens ?? null,
        tokens_out: answer.usage?.output_tokens ?? null,
        request_id: context.requestId,
        correlation_id: context.correlationId,
      });

      return {
        response: success({
          question_id: questionRow.id,
          session_id: sessionId,
          answer: answer.text,
          model: answer.model,
        }, context.requestId),
        userId: authUser.id,
        correlationId: context.correlationId,
      };
    } catch (error) {
      const appError = error instanceof AppError ? error : new AppError('qa_upstream_error', 'Question answering failed', 500);
      await serviceClient
        .from('conversation_questions')
        .update({
          status: 'failed',
          error_code: appError.code,
        })
        .eq('id', questionRow.id);
      throw appError;
    }
  });
});
