import { assertMethod, withErrorHandling } from '../_shared/http.ts';
import { buildRequestContext } from '../_shared/request.ts';
import { requireInternalSecret } from '../_shared/auth.ts';
import { createServiceClient } from '../_shared/clients.ts';
import { AppError } from '../_shared/errors.ts';
import { success } from '../_shared/response.ts';

Deno.serve(async (request) => {
  const context = buildRequestContext(request);

  return await withErrorHandling('evaluate-cost-budgets', context.requestId, async () => {
    assertMethod(request, 'POST');
    await requireInternalSecret(request);
    const serviceClient = createServiceClient();

    const windowStart = new Date();
    windowStart.setUTCDate(windowStart.getUTCDate() - windowStart.getUTCDay());
    windowStart.setUTCHours(0, 0, 0, 0);
    const windowEnd = new Date(windowStart);
    windowEnd.setUTCDate(windowEnd.getUTCDate() + 6);

    const { data: rules, error: rulesError } = await serviceClient
      .from('cost_budget_rules')
      .select('*')
      .eq('is_enabled', true);
    if (rulesError) {
      throw new AppError('budget_rules_query_failed', rulesError.message, 500);
    }

    const { data: calls, error: callsError } = await serviceClient
      .from('ai_model_calls')
      .select('estimated_cost_usd')
      .gte('created_at', windowStart.toISOString())
      .lte('created_at', windowEnd.toISOString());
    if (callsError) {
      throw new AppError('budget_calls_query_failed', callsError.message, 500);
    }

    const spentUsd = (calls ?? []).reduce((sum, call) => sum + Number(call.estimated_cost_usd ?? 0), 0);
    let processed = 0;

    for (const rule of rules ?? []) {
      const { data: windowRow, error: windowError } = await serviceClient.from('cost_budget_windows').upsert({
        scope_type: rule.scope_type,
        scope_id: rule.scope_id,
        window_start: windowStart.toISOString().slice(0, 10),
        window_end: windowEnd.toISOString().slice(0, 10),
        spent_usd: spentUsd,
        updated_at: new Date().toISOString(),
      }, {
        onConflict: 'scope_type,scope_id,window_start,window_end',
      }).select('*').single();

      if (windowError || !windowRow) {
        throw new AppError('budget_window_upsert_failed', windowError?.message ?? 'Unable to upsert cost window', 500);
      }

      for (const threshold of [50, 80, 100]) {
        if (spentUsd >= Number(rule.cap_usd) * (threshold / 100)) {
          await serviceClient.from('cost_budget_alerts').upsert({
            rule_id: rule.id,
            window_id: windowRow.id,
            threshold_percent: threshold,
          }, {
            onConflict: 'rule_id,window_id,threshold_percent',
          });
        }
      }

      processed += 1;
    }

    return {
      response: success({
        processed_rules: processed,
        spent_usd: spentUsd,
      }, context.requestId),
    };
  });
});
