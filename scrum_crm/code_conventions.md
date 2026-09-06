- [1. Code writing guide](#1-code-writing-guide)
  - [1.1. Values](#11-values)
    - [1.1.1. Readability](#111-readability)
    - [1.1.2. Vandal-resistance](#112-vandal-resistance)
    - [1.1.3. Keeping entropy at a minimum](#113-keeping-entropy-at-a-minimum)
  - [1.2. Principles](#12-principles)
  - [1.3. General rules](#13-general-rules)
    - [1.3.1. Unused code is forbidden](#131-unused-code-is-forbidden)
    - [1.3.2. Leaving debug code is forbidden](#132-leaving-debug-code-is-forbidden)
  - [1.4. Working with variables](#14-working-with-variables)
    - [1.4.1. Variable names use camelCase](#141-variable-names-use-camelcase)
    - [1.4.2. A variable name must match its contents](#142-a-variable-name-must-match-its-contents)
    - [1.4.3. Frequently used objects are named identically across the whole project](#143-frequently-used-objects-are-named-identically-across-the-whole-project)
    - [1.4.4. An object's qualifier is added to its name](#144-an-objects-qualifier-is-added-to-its-name)
    - [1.4.5. Variables holding an object's property must include the object's name](#145-variables-holding-an-objects-property-must-include-the-objects-name)
    - [1.4.6. Variables should be named in correct English where possible](#146-variables-should-be-named-in-correct-english-where-possible)
  - [1.5. Boolean variables and methods](#15-boolean-variables-and-methods)
    - [1.5.1. Names of boolean methods and variables must contain the verb `is`, `has` or `can`](#151-names-of-boolean-methods-and-variables-must-contain-the-verb-is-has-or-can)
    - [1.5.2. Negative boolean names are forbidden](#152-negative-boolean-names-are-forbidden)
    - [1.5.3. Event names start with `on`, followed by the event name and the event object](#153-event-names-start-with-on-followed-by-the-event-name-and-the-event-object)
  - [1.6. Composing methods](#16-composing-methods)
    - [1.6.1. If code can be grouped, extract it into a method](#161-if-code-can-be-grouped-extract-it-into-a-method)
    - [1.6.2. Do not extract a method when its body is more obvious than the method itself](#162-do-not-extract-a-method-when-its-body-is-more-obvious-than-the-method-itself)
    - [1.6.3. In hard-to-read expressions, put the result of the expression into a named variable](#163-in-hard-to-read-expressions-put-the-result-of-the-expression-into-a-named-variable)
    - [1.6.4. If a temporary variable holds the result of one simple expression and nothing else, replace references to the variable with the expression itself](#164-if-a-temporary-variable-holds-the-result-of-one-simple-expression-and-nothing-else-replace-references-to-the-variable-with-the-expression-itself)
    - [1.6.5. If a local variable stores different intermediate values inside a method, use a separate variable for each value. Every variable is responsible for exactly one thing](#165-if-a-local-variable-stores-different-intermediate-values-inside-a-method-use-a-separate-variable-for-each-value-every-variable-is-responsible-for-exactly-one-thing)
  - [1.7. Organizing data](#17-organizing-data)
    - [1.7.1. Do not access private fields directly inside a class](#171-do-not-access-private-fields-directly-inside-a-class)
    - [1.7.2. If a number in the code carries a specific meaning, replace it with a constant whose human-readable name explains that meaning](#172-if-a-number-in-the-code-carries-a-specific-meaning-replace-it-with-a-constant-whose-human-readable-name-explains-that-meaning)
  - [1.8. Simplifying conditional expressions](#18-simplifying-conditional-expressions)
    - [1.8.1. If a conditional (if-then/else or switch) is complex, extract each complex part — the condition, then and else — into its own method](#181-if-a-conditional-if-thenelse-or-switch-is-complex-extract-each-complex-part--the-condition-then-and-else--into-its-own-method)
    - [1.8.2. If several conditionals lead to the same result or action, merge all the conditions into one conditional](#182-if-several-conditionals-lead-to-the-same-result-or-action-merge-all-the-conditions-into-one-conditional)
    - [1.8.3. If the same code fragment appears in every branch of a conditional, move it out of the conditional](#183-if-the-same-code-fragment-appears-in-every-branch-of-a-conditional-move-it-out-of-the-conditional)
    - [1.8.4. If a boolean variable acts as a control flag for several boolean expressions, use break, continue and return instead of that variable](#184-if-a-boolean-variable-acts-as-a-control-flag-for-several-boolean-expressions-use-break-continue-and-return-instead-of-that-variable)
    - [1.8.5. If nested conditionals obscure the normal path of execution, extract all special/edge-case checks into guard clauses placed before the main checks. Ideally you end up with a "flat" list of conditionals, one after another](#185-if-nested-conditionals-obscure-the-normal-path-of-execution-extract-all-specialedge-case-checks-into-guard-clauses-placed-before-the-main-checks-ideally-you-end-up-with-a-flat-list-of-conditionals-one-after-another)

# 1. Code writing guide

This document contains our Code Conventions.

The current version of our Code Conventions always lives here. We refer
to it during Code Review.

Code Conventions are rules to follow when writing any code. We
distinguish Code Style from Code Conventions. For us, Code Style is the
code's appearance — indentation, commas, braces and so on — while Code
Conventions are the code's meaning: correct algorithms, semantically
correct names for variables and methods, correct code composition.
Code Style compliance is easy to check automatically; Code Conventions
compliance can, in most cases, only be checked by a human.

The examples below are in TypeScript, but the rules apply to any
language. Language adaptation: variable naming follows the language's
own convention (e.g. PEP8 `snake_case` in Python — rule 1.4.1 applies
only to TS/JS); everything else (name semantics 1.4.2–1.4.6, boolean
naming 1.5, method composition 1.6, constants over magic numbers 1.7.2,
guard clauses 1.8.5, the ban on dead and debug code 1.3) applies
unchanged everywhere.

## 1.1. Values

The main goal of Code Conventions is keeping the cost of developing and
maintaining the code low over the long run.

The core values that serve this goal:

### 1.1.1. Readability

Code must be easy to read, not easy to write. Syntactic sugar aimed at
faster writing rather than easier later reading is harmful.
Note that raw performance is not a value here: a less-than-optimal loop
that is easy to understand beats a fast but convoluted one. Don't
economize on variables, on letters in their names, on RAM, and so on.

### 1.1.2. Vandal-resistance

Write code so that a developer who later works with it has as little
opportunity as possible to introduce a bug. For example, cover with
tests not only the edge conditions but also the cases that may appear
as the code is extended and refactored.

### 1.1.3. Keeping entropy at a minimum

Entropy is the amount of information the project consists of (the
project's information capacity). The project's code must satisfy the
product requirements while keeping entropy as low as possible.

## 1.2. Principles

Principles are the ways we uphold the values above. They are slightly
more concrete and reflect the core methodologies and approaches we
follow.

Code must be:

- Understandable and explicit. Explicit is better than implicit — e.g.
  no magic methods. `exit` and any other operators that can terminate
  or alter the process must not be used.
- Convenient to use now
- Convenient to use in the future
- Striving to follow [KISS](https://en.wikipedia.org/wiki/KISS_principle),
  [SOLID](https://en.wikipedia.org/wiki/SOLID),
  [GRASP](https://en.wikipedia.org/wiki/GRASP_(object-oriented_design))
- Low coupling, high cohesion (described in detail in GRASP). Any part
  of the system must have isolated logic and, where needed, an external
  interface for working with that logic. Any internal part must be
  changeable without harming external systems.
- Automatically refactorable in an IDE (e.g. Find Usages and Rename) —
  i.e. linked together by typing and documentation
- The database must not store pieces of code (not even class, variable
  or constant names): that makes automatic refactoring impossible
- Sequential. Code reads top to bottom. The reader must not hold things
  in their head, jump back, or reinterpret earlier code. For example,
  avoid trailing-condition loops `do {} while ();`
- Of minimal [cyclomatic complexity](https://en.wikipedia.org/wiki/Cyclomatic_complexity)

## 1.3. General rules

### 1.3.1. Unused code is forbidden

If code can be removed without changing the system's behavior, it must
not be there.

Problem:
```ts
if (false) {
    legacyMethodCall();
}
// ...
let legacyCondition = true;
if (legacyCondition) {
    finalizeData(data);
}
```

Solution:
```ts
// ...
finalizeData(data);
```

### 1.3.2. Leaving debug code is forbidden

Problem:
```ts
  const product = getProduct(id);
  console.log(product);
```

Solution:
```ts
  const product = getProduct(id);
```

## 1.4. Working with variables

### 1.4.1. Variable names use camelCase

### 1.4.2. A variable name must match its contents

No cryptic short names like `c`. Don't name a variable `day` and store
an array of that day's statistics in it.

### 1.4.3. Frequently used objects are named identically across the whole project

Problem:
```ts
const customer = new User();
const client = new User();
const object = new User();
```

Solution:
```ts
const user = new User();
```

### 1.4.4. An object's qualifier is added to its name

If a project is filtered by some attribute, that attribute goes into
the name — e.g. `unpaidProject`.

### 1.4.5. Variables holding an object's property must include the object's name

Problem:
```ts
const project = new Project();
const name = project.name;
const surname = project.surname;
```

Solution:
```ts
const project = new Project();
const projectName = project.name;
```

### 1.4.6. Variables should be named in correct English where possible

Problem:
```ts
const usersStored = [];
```

Solution:
```ts
const storedUsers = [];
```

Exception: fields or constants grouped by some attribute. There a
prefix is allowed:

```ts
class ProjectInfo {
    static readonly STATUS_READY = 1;
    static readonly STATUS_BLOCKED = 2;

    public billingIsPaid;
    public billingPaidDate;
    public billingSum;
}
```

## 1.5. Boolean variables and methods

### 1.5.1. Names of boolean methods and variables must contain the verb `is`, `has` or `can`

Variables are named by describing their contents; methods by asking a
question. If a variable holds an object's property, follow the rule
[an object's qualifier is added to its name](#144-an-objects-qualifier-is-added-to-its-name).

Problem:
```ts
const isUserValid = user.valid();
const isProjectAnalytics = accessManager.getProjectAccess(project, 'analytics');
```

Solution:
```ts
const userIsValid = user.isValid();
const projectCanAccessAnalytics = accessManager.canProjectAccess(project, 'analytics');
```

Getters are named like variables:

```ts
class User {
    private billingIsPaid;
    private isEnabled;

    get isEnabled() {
        return this.isEnabled;
    }

    get billingIsPaid() {
        return this.billingIsPaid;
    }
}
```

This naming makes conditions read naturally:

```ts
// if user is valid, then do something
if (userIsValid) {
    // do something
}
```

### 1.5.2. Negative boolean names are forbidden

Problem:
```ts
if (project.isInvalid()) {
    // ...
}
if (project.isNotValid()) {
    // ...
}
if (accessManager.isAccessDenied()) {
    // ...
}
```

Solution:
```ts
if (!project.isValid()) {
    // ...
}
if (!accessManager.isAccessAllowed()) {
    // ...
}
if (accessManager.canAccess()) {
    // ...
}
```

### 1.5.3. Event names start with `on`, followed by the event name and the event object

Examples:
```ts
onClickButton() {
  // ...
}
onInputSearch() {
  // ...
},
```

## 1.6. Composing methods

### 1.6.1. If code can be grouped, extract it into a method

Problem:

```ts
printUser(): void {
  printBanner();

  // Print details.
  console.log("name: " + name);
  console.log("amount: " + getOutstanding());
}
```

Solution:

```ts
printUser(): void {
  printBanner();
  printDetails(getOutstanding());
}

printDetails(outstanding: number): void {
  console.log("name: " + name);
  console.log("amount: " + outstanding);
}
```

### 1.6.2. Do not extract a method when its body is more obvious than the method itself

Problem:
```ts
class PizzaDelivery {
  // ...
  getRating(): number {
    return moreThanFiveLateDeliveries() ? 2 : 1;
  }
  moreThanFiveLateDeliveries(): boolean {
    return numberOfLateDeliveries > 5;
  }
}
```

Solution:
```ts
class PizzaDelivery {
  // ...
  getRating(): number {
    return numberOfLateDeliveries > 5 ? 2 : 1;
  }
}
```

### 1.6.3. In hard-to-read expressions, put the result of the expression into a named variable

Problem:
```ts
renderBanner(): void {
  if ((platform.toUpperCase().indexOf("MAC") > -1) &&
       (browser.toUpperCase().indexOf("IE") > -1) &&
        wasInitialized() && resize > 0 )
  {
    // do something
  }
}
```

Solution:
```ts
renderBanner(): void {
  const isMacOs = platform.toUpperCase().indexOf("MAC") > -1;
  const isIE = browser.toUpperCase().indexOf("IE") > -1;
  const wasResized = resize > 0;

  if (isMacOs && isIE && wasInitialized() && wasResized) {
    // do something
  }
}
```

### 1.6.4. If a temporary variable holds the result of one simple expression and nothing else, replace references to the variable with the expression itself

Problem:
```ts
hasDiscount(order: Order): boolean {
  let basePrice: number = order.basePrice();
  return basePrice > 1000;
}
```

Solution:
```ts
hasDiscount(order: Order): boolean {
  return order.basePrice() > 1000;
}
```

### 1.6.5. If a local variable stores different intermediate values inside a method, use a separate variable for each value. Every variable is responsible for exactly one thing

Problem:
```ts
let temp = 2 * (height + width);
console.log(temp);
temp = height * width;
console.log(temp);
```

Solution:
```ts
const perimeter = 2 * (height + width);
console.log(perimeter);
const area = height * width;
console.log(area);
```

## 1.7. Organizing data

### 1.7.1. Do not access private fields directly inside a class

Problem:
```ts
class Range {
  private low: number
  private high: number;
  includes(arg: number): boolean {
    return arg >= low && arg <= high;
  }
}
```

Solution:
```ts
class Range {
  private low: number
  private high: number;
  includes(arg: number): boolean {
    return arg >= getLow() && arg <= getHigh();
  }
  getLow(): number {
    return low;
  }
  getHigh(): number {
    return high;
  }
}
```

### 1.7.2. If a number in the code carries a specific meaning, replace it with a constant whose human-readable name explains that meaning

Problem:
```ts
potentialEnergy(mass: number, height: number): number {
  return mass * height * 9.81;
}
```

Solution:
```ts
static const GRAVITATIONAL_CONSTANT = 9.81;

potentialEnergy(mass: number, height: number): number {
  return mass * height * GRAVITATIONAL_CONSTANT;
}
```

## 1.8. Simplifying conditional expressions

### 1.8.1. If a conditional (if-then/else or switch) is complex, extract each complex part — the condition, then and else — into its own method

Problem:
```ts
if (date.before(SUMMER_START) || date.after(SUMMER_END)) {
  charge = quantity * winterRate + winterServiceCharge;
}
else {
  charge = quantity * summerRate;
}
```

Solution:
```ts
if (isSummer(date)) {
  charge = summerCharge(quantity);
}
else {
  charge = winterCharge(quantity);
}
```

### 1.8.2. If several conditionals lead to the same result or action, merge all the conditions into one conditional

Problem:
```ts
disabilityAmount(): number {
  if (seniority < 2) {
    return 0;
  }
  if (monthsDisabled > 12) {
    return 0;
  }
  if (isPartTime) {
    return 0;
  }
  // Compute the disability amount.
  // ...
}
```

Solution:
```ts
disabilityAmount(): number {
  if (isNotEligibleForDisability()) {
    return 0;
  }
  // Compute the disability amount.
  // ...
}
```

### 1.8.3. If the same code fragment appears in every branch of a conditional, move it out of the conditional

Problem:
```ts
if (isSpecialDeal()) {
  total = price * 0.95;
  send();
}
else {
  total = price * 0.98;
  send();
}
```

Solution:
```ts
if (isSpecialDeal()) {
  total = price * 0.95;
}
else {
  total = price * 0.98;
}
send();
```

### 1.8.4. If a boolean variable acts as a control flag for several boolean expressions, use break, continue and return instead of that variable

```ts
// The problem and the solution are self-evident; an example is available on request
```

### 1.8.5. If nested conditionals obscure the normal path of execution, extract all special/edge-case checks into guard clauses placed before the main checks. Ideally you end up with a "flat" list of conditionals, one after another

Problem:
```ts
getPayAmount(): number {
  let result: number;
  if (isDead){
    result = deadAmount();
  }
  else {
    if (isSeparated){
      result = separatedAmount();
    }
    else {
      if (isRetired){
        result = retiredAmount();
      }
      else{
        result = normalPayAmount();
      }
    }
  }
  return result;
}
```

Solution:
```ts
getPayAmount(): number {
  if (isDead){
    return deadAmount();
  }
  if (isSeparated){
    return separatedAmount();
  }
  if (isRetired){
    return retiredAmount();
  }
  return normalPayAmount();
}
```
