---
task: Build "ts-narrow" - A TypeScript Type Narrowing Debugger
test_command: "npm test"
completion_criteria:
  - CLI parses TypeScript files
  - Tracks type of a variable through control flow
  - Explains narrowing at each step
  - Handles if/else, typeof, instanceof, truthiness
  - Outputs human-readable explanation
  - Final type at target line reflects narrowed scope correctly
  - All test assertions pass
max_iterations: 30
---

# Task: Build "ts-narrow" - TypeScript Type Narrowing Debugger

Build a CLI tool that explains how TypeScript narrows types through control flow.

## The Problem

TypeScript's type narrowing is powerful but opaque. When narrowing doesn't work as expected, developers have no way to understand why.

## The Solution

A CLI that traces a variable through code and explains each narrowing step:

```bash
$ npx ts-node src/index.ts analyze test/truthiness.ts --variable x --line 4
```

## Technical Approach

Use the TypeScript Compiler API to:
1. Parse the source file into an AST
2. Create a type checker instance
3. Walk the AST tracking control flow
4. At each narrowing point, record what happened
5. Generate human-readable explanations

## Success Criteria

### Phase 1: Basic Parsing & Type Extraction
1. [ ] CLI accepts a TypeScript file path
2. [ ] Parses file using TypeScript Compiler API
3. [ ] Can find a variable declaration by name
4. [ ] Can get the type of a variable at declaration

### Phase 2: Control Flow Tracking
5. [ ] Tracks variable through if/else blocks
6. [ ] Identifies narrowing points (if conditions)
7. [ ] Records type before and after each narrowing
8. [ ] Handles nested if/else correctly

### Phase 3: Narrowing Detection
9. [ ] Detects truthiness narrowing (`if (x)`)
10. [ ] Detects typeof narrowing (`if (typeof x === 'string')`)
11. [ ] Detects instanceof narrowing (`if (x instanceof Error)`)
12. [ ] Detects equality narrowing (`if (x === null)`)
13. [ ] Detects discriminated union narrowing (`if (x.kind === 'a')`)

### Phase 4: Output & Explanation
14. [ ] Generates step-by-step trace output
15. [ ] Explains what caused each narrowing
16. [ ] Shows what types were eliminated
17. [ ] **CRITICAL: Final type at target line reflects the NARROWED type, not the original type**
18. [ ] Handles "type not narrowed" cases with explanation

### Phase 5: Edge Cases & Polish
19. [ ] Works with type aliases and interfaces
20. [ ] Handles function parameters
21. [ ] Works with optional chaining (`x?.foo`)
22. [ ] Provides helpful error for invalid inputs
23. [ ] Has --json output option for tooling

---

## MANDATORY TEST CASES

The test runner (`test/run-tests.js`) MUST verify these EXACT outputs. Tests that don't assert on exact expected strings are invalid.

### Test 1: test/truthiness.ts
```typescript
function example(x: string | null) {
  if (x) {
    console.log(x.toUpperCase()) // line 4
  }
}
```

**Command:** `npx ts-node src/index.ts analyze test/truthiness.ts --variable x --line 4`

**REQUIRED output must contain:** `Final type at line 4: string`

**MUST NOT contain:** `Final type at line 4: string | null`

Why: Line 4 is INSIDE the `if (x)` block, so `x` has been narrowed from `string | null` to `string`.

---

### Test 2: test/typeof.ts
```typescript
function process(value: string | number) {
  if (typeof value === 'string') {
    return value.toUpperCase() // line 4
  }
  return value.toFixed(2) // line 6
}
```

**Command (line 4):** `npx ts-node src/index.ts analyze test/typeof.ts --variable value --line 4`
**REQUIRED:** `Final type at line 4: string`

**Command (line 6):** `npx ts-node src/index.ts analyze test/typeof.ts --variable value --line 6`
**REQUIRED:** `Final type at line 6: number`

---

### Test 3: test/discriminated.ts
```typescript
type Result = 
  | { ok: true; data: string }
  | { ok: false; error: Error }

function handle(result: Result) {
  if (result.ok) {
    console.log(result.data) // line 8
  } else {
    console.log(result.error) // line 10
  }
}
```

**Command (line 8):** `npx ts-node src/index.ts analyze test/discriminated.ts --variable result --line 8`
**REQUIRED:** Output must indicate type is narrowed to the `{ ok: true; data: string }` variant

**Command (line 10):** `npx ts-node src/index.ts analyze test/discriminated.ts --variable result --line 10`
**REQUIRED:** Output must indicate type is narrowed to the `{ ok: false; error: Error }` variant

---

### Test 4: test/no-narrow.ts (Negative case)
```typescript
function broken(x: string | null) {
  const y = x // y copies x's type
  if (x) {
    console.log(y.toUpperCase()) // line 5 - y is NOT narrowed!
  }
}
```

**Command:** `npx ts-node src/index.ts analyze test/no-narrow.ts --variable y --line 5`
**REQUIRED:** `Final type at line 5: string | null`

Why: The `if (x)` check narrows `x`, NOT `y`. Variable `y` retains its original type.

---

## Test Runner Requirements

Create `test/run-tests.js` that:

```javascript
// PSEUDOCODE - implement this properly
const tests = [
  {
    name: "truthiness narrowing",
    file: "test/truthiness.ts",
    variable: "x", 
    line: 4,
    mustContain: "Final type at line 4: string",
    mustNotContain: "Final type at line 4: string | null"
  },
  // ... more tests
];

for (const test of tests) {
  const output = runCommand(`npx ts-node src/index.ts analyze ${test.file} --variable ${test.variable} --line ${test.line}`);
  
  if (test.mustContain && !output.includes(test.mustContain)) {
    console.error(`FAIL: ${test.name}`);
    console.error(`  Expected to contain: "${test.mustContain}"`);
    console.error(`  Actual output: "${output}"`);
    process.exit(1);
  }
  
  if (test.mustNotContain && output.includes(test.mustNotContain)) {
    console.error(`FAIL: ${test.name}`);
    console.error(`  Must NOT contain: "${test.mustNotContain}"`);
    console.error(`  Actual output: "${output}"`);
    process.exit(1);
  }
  
  console.log(`PASS: ${test.name}`);
}

console.log("All tests passed!");
process.exit(0);
```

**The test runner MUST:**
1. Assert on EXACT expected strings (mustContain)
2. Assert on strings that MUST NOT appear (mustNotContain)
3. Exit with code 1 if ANY assertion fails
4. Exit with code 0 only if ALL assertions pass

---

## File Structure

```
ts-narrow/
├── src/
│   ├── index.ts          # CLI entry point
│   ├── parser.ts         # TypeScript parsing utilities
│   ├── analyzer.ts       # Control flow analysis
│   ├── narrowing.ts      # Narrowing detection logic
│   ├── formatter.ts      # Output formatting
│   └── types.ts          # Internal type definitions
├── test/
│   ├── truthiness.ts
│   ├── typeof.ts
│   ├── discriminated.ts
│   ├── no-narrow.ts
│   └── run-tests.js      # Test runner with assertions
├── package.json
├── tsconfig.json
└── README.md
```

## Dependencies

- `typescript` (for Compiler API) - ONLY external dependency
- Node.js built-ins only otherwise

## Constraints

- Must use TypeScript Compiler API (not regex/string parsing)
- No external dependencies except `typescript`
- **Tests must assert on exact expected outputs**
- **Task is NOT complete until `npm test` exits with code 0**

---

## Ralph Instructions

1. Work through phases in order
2. **Run `npm test` after EVERY change**
3. If tests fail, read the failure message and fix the code
4. A criterion is only complete when relevant tests pass
5. Commit after completing each criterion
6. **Criterion 17 is CRITICAL** - the final type must reflect narrowing scope
7. When ALL criteria are [x] AND `npm test` passes: `RALPH_COMPLETE`
8. If stuck on same issue 3+ times: `RALPH_GUTTER`
