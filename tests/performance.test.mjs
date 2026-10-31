import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';

const read = (path) => readFileSync(new URL(`../${path}`, import.meta.url), 'utf8');

test('workspace identity and gym resolution are request-cached and use one joined read', () => {
  const workspace = read('src/lib/workspace.ts');
  assert.match(workspace, /import \{ cache \} from "react"/);
  assert.match(workspace, /getVerifiedUser = cache\(/);
  assert.match(workspace, /requireActiveGym = cache\(/);
  assert.match(workspace, /gym:gyms!gym_users_gym_id_fkey!inner/);
});

test('dynamic app navigation has a loading boundary and links opt into prefetch', () => {
  const loading = read('src/app/(workspace)/app/loading.tsx');
  const shell = read('src/components/workspace-shell.tsx');
  assert.match(loading, /role="status"/);
  assert.match(loading, /skeleton/);
  assert.match(shell, /prefetch/);
});

test('server-action forms expose pending feedback without bypassing server actions', () => {
  const component = read('src/components/submit-button.tsx');
  const members = read('src/app/(workspace)/app/members/page.tsx');
  assert.match(component, /useFormStatus/);
  assert.match(component, /aria-busy=\{pending\}/);
  assert.match(members, /<SubmitButton/);
});
