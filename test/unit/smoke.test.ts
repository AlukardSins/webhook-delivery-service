import assert from 'node:assert/strict';
import { test } from 'node:test';

// Proves CI discovers and runs tests: a run reporting "tests 0" would also pass.
test('adds two numbers when both are positive', () => {
  const a = 1;
  const b = 1;

  const sum = a + b;

  assert.equal(sum, 2);
});
