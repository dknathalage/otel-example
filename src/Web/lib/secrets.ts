import 'server-only';
import { SecretManagerServiceClient } from '@google-cloud/secret-manager';

const client = new SecretManagerServiceClient();

/**
 * Server-only Google Secret Manager read (mirrors Core.Secrets on the .NET side).
 * Used when the web app needs a server-held secret such as a browser ingest token.
 */
export async function getSecret(project: string, name: string): Promise<string> {
  const [version] = await client.accessSecretVersion({
    name: `projects/${project}/secrets/${name}/versions/latest`,
  });
  return version.payload?.data?.toString() ?? '';
}
