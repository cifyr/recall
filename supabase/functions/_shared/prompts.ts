import { AppError } from './errors.ts';
import { createServiceClient } from './clients.ts';

export async function getPromptTemplate(name: string, version?: number) {
  const serviceClient = createServiceClient();
  let query = serviceClient
    .from('prompt_templates')
    .select('*')
    .eq('name', name)
    .eq('is_active', true)
    .order('version', { ascending: false })
    .limit(1);

  if (version) {
    query = serviceClient
      .from('prompt_templates')
      .select('*')
      .eq('name', name)
      .eq('version', version)
      .eq('is_active', true)
      .limit(1);
  }

  const { data, error } = await query.maybeSingle();
  if (error) {
    throw new AppError('prompt_template_lookup_failed', error.message, 500);
  }
  if (!data) {
    throw new AppError('prompt_template_missing', `Prompt template not found: ${name}`, 404);
  }
  return data;
}
