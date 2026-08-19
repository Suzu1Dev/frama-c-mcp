# General development workflow specifications

> This document is a project development process specification template for Claude and developers to abide by.
> In a specific project, reference this document through CLAUDE.md: `@docs/workflow.md`

---

## 1. Claude Code of Conduct

### 1.1 Core Principles

- **Plan first, then do it**: After receiving the task, explain your understanding and execution of the plan first, and then start implementing it after the user confirms it.
- **Single-step advancement**: Only complete one clear step (one module, one function, a set of related modifications) at a time, and stop and wait for feedback after completion
- **Minimum changes**: No unnecessary refactoring, no introduction of undiscussed dependencies, no changes to irrelevant files
- **Design before code**: When new features or architecture changes are involved, the design document must be produced or updated first, and coding can only be done after confirmation.
- **Honest reporting**: When you encounter an uncertain problem or find a contradiction or omission in the design document, explain it to the user immediately, and do not make assumptions or bypass it on your own.

### 1.2 Operation ban

- **It is forbidden** to modify the test case in order to make the test pass (unless it is confirmed that the error is the test case itself)
- **Prohibit** starting coding implementation without reading the design document
- **BANNED** Commit large-scale changes across multiple modules at once
- **Prohibited** from advancing to the implementation stage without confirmation before the design stage
- **Disable** deleting or commenting out failed test cases

---

## 2. Design stage process

When adding core functions, advance the design in the following three stages. Each stage produces design documents, which are confirmed by the user before entering the next stage.

### 2.1 Research stage

Goal: Fully understand the problem domain to avoid reinventing the wheel or missing key solutions.

Output research report, including:
1. Sort out the existing relevant infrastructure and capabilities of this project
2. Research existing external implementations and academic literature, sort out algorithm variants, known optimizations, and applicable scenarios
3. Compare the advantages, disadvantages and applicable conditions of each plan
4. Give recommended solutions and reasons

### 2.2 Architecture Phase

Goal: Determine the overall structure, define module boundaries and interaction contracts.

Output architecture documents, including:
1. Core process description (complete path of data from input to output)
2. Module division and **functional specifications** of each module (see §3 Specification Writing Standards)
3. **Interface specification** between modules (how data flows, calling relationship)
4. Key design decisions and their rationale

### 2.3 Refinement stage

Goal: Implement the architecture into a function-level design that can be directly coded.

Output detailed documents, including:
1. List the functions that need to be implemented module by module: function signature, function description, calling relationship
2. Reuse points with existing code
3. Error handling strategy

**Constraints**: Refinement must not change the module divisions, interface specifications and core processes determined in the architecture phase. If changes are needed, go back to the architecture stage and discuss it again.

### 2.4 Design document review

After the design is completed, it must pass review before entering implementation:
1. The architectural design can achieve the original goals and the correctness is guaranteed
2. In the refinement stage, the function design of each module satisfies the functional specification and interface specification of the module.
3. The document is unambiguous and can be directly used for development and implementation

---

## 3. Specification writing standards

The specifications in the design document are written in a semi-formal style, taking into account both accuracy and readability.

### 3.1 Function specification format

The specification of each module or key function contains the following elements:

```
Function/module name: <name>

Function description: <What to do in one sentence>

Preconditions (Requires):
  - <Conditions that must be met before calling, in natural language + mathematical expression>

Postconditions (Ensures):
  - <Properties that are guaranteed to be true after calling>

Invariants: (if applicable)
  - <Properties maintained throughout execution>

Side effects: <none/what status was modified>
```

### 3.2 Interface specification format

The interface specification between modules describes the data transfer contract:

```
Interface: <Module A> → <Module B>

Input data: <type and semantic description>
Output data: <type and semantic description>

The agreement stipulates:
  - <Responsibility of the caller (guarantee what conditions the input meets)>
  - <Responsibility of the callee (what conditions are guaranteed to be met by the output)>
```

### 3.3 Concurrency specification format (optional)

Modules involving multi-threading/parallel computing must additionally supplement concurrency specifications. Projects that do not involve concurrency can skip this section.

```
Concurrency unit: <function/module name>

Shared resources:
  - <resource name>: <type and semantic description>

Locking Protocol:
  - <Acquisition and release sequence, such as: acquire lock_A first and then acquire lock_B, reverse order is prohibited>
  - <Lock granularity description: coarse-grained/fine-grained/read-write lock>

Ordering Constraints:
  - <The sequence relationship between operations, such as: write(X) must happen-before read(X)>
  - <Memory order requirement (if applicable): acquire/release/seq_cst>

Rely-Guarantee Conditions: (if applicable)
  - Rely (environment commitment): <What other threads are guaranteed not to do / what properties to maintain>
  - Guarantee (self-commitment): <What this thread guarantees to do/not do with shared state>

Thread safety conclusion:
  - <Is this module/function thread-safe and under what conditions>
```

**Time to use**: Identify concurrency boundaries in the architecture phase, and supplement concurrency specifications for each function involving shared state in the refinement phase.

### 3.4 Writing Principles

- Condition descriptions should preferably use mathematical expressions (such as `n ≥ 0`, `deg(f) < deg(g)`), supplemented by natural language explanations
- Avoid vague terms ("reasonable", "appropriate"), all constraints must be decidable
- For complex algorithms, pseudocode can be attached to assist the description, but the specification itself must be independent of implementation details

---

## 4. Implementation stage process

Strictly follow the design document and implement it in modules, and advance in sequence according to the module order in the design document.

### 4.1 Advance module by module

Development process of each module:
1. Read the design document of the module (functional specification, interface specification, function design)
2. Coding implementation
3. Write the test and run it
4. Code review
5. After passing the review, proceed to the next module.

### 4.2 Code review

Review content:
- **Consistency**: Whether the interface, function, and calling relationship between the implementation and the design document match
- **Style**: consistent with the existing code of the project
- **Correctness**: Whether there are CWE defects, logical errors, redundant code
- **Performance**: Are there any performance redundancy points such as unnecessary copies and repeated calculations?
- **Maintainability**: Whether the module boundaries are clear and whether there are functional misalignments (code that should be merged or moved to other modules)

### 4.3 Code test layering

1. **Basic Function Test** — Write use cases according to the design document to verify the correctness of the main function (function → module → overall layer-by-layer coverage)
2. **Edge Case Testing** — covering boundary conditions and special inputs
3. **Random testing** — Randomly generate a sufficiently broad range of use cases and cross-validate with the reference implementation when conditions permit.

### 4.4 Test failure handling

When the test fails, it is forbidden to blindly modify the test case to make it pass. The reasons must be analyzed first:
- **Test case writing error** — Correct the test case and explain the reason for the correction
- **Tested object bug** — retain the original test cases and recurring use cases, record the bug in the test report, and do not bypass it
- **The lack of API leads to inconvenience of use** — recorded in the test report as a subsequent improvement item

---

## 5. Repair and iteration process

When a bug is found or additional functionality is needed:

1. **Make a list of issues** — identify bugs that need to be fixed and features that need to be added
2. **Classification processing**:
   - **Obvious errors** (clerical errors, off-by-one and other local problems) - direct repairs and supplementary test cases
   - **Other situations** (unreasonable interface, missing scenarios, design defects, new functions) - Return to the design stage, adjust the design document first, and then execute according to the implementation process
3. **draw inferences from one instance** — sort out whether there are other similar problems, reflect on the causes of the problems, and supplement relevant test cases
4. **Regression Test** — Supplement the use cases where the bug was discovered this time as regression use cases, and rerun the tests of all existing modules to ensure there is no regression.

---

## 6. Document Management

### 6.1 Directory structure

```
docs/
├── research/ # research report
│ └── <function name>-research.md
├── design/ # Architecture documents and detailed documents
│ └── <function name>/
│       ├── architecture.md
│       └── detailed-design.md
├── test-reports/ # Test reports and bug records
│ └── <function name>-test-report.md
└── workflow.md # This document
```

### 6.2 Document Version Control

- Design documents are included in Git management along with the code
- Modifications to the design document must indicate the reason in the commit message (such as `docs: Update XXX module interface specification to adapt to YYY changes`)
- When the document is too large, split it into multiple files and use directory index in the main document.

### 6.3 Document evolution principles

- If errors or deficiencies in the design document are found during the implementation process, **update the document first and then change the code** to keep the document and code synchronized
- Check after each iteration that the documentation still accurately reflects the current implementation
- Abandoned design decisions will not be deleted, but marked `[Abandoned]` and the alternatives and reasons will be explained.

---

## 7. Process quick check

```
New feature development:
  Research → [Confirm] → Architecture → [Confirm] → Refinement → [Confirm] → Review → Module-by-module implementation + testing + review

Bug fixes:
  Local errors → direct repair + supplementary testing + regression
  Other situations → Update design → Execute according to implementation process + regression

Claude each step:
  Describe plan → [Waiting for confirmation] → Execute single step → Report results → [Waiting for feedback]
```
