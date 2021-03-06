# CHANGELOG

 -  0.7.2 (2019-12-30)
     *  Ignore partial rules when converting packages to objects.
     *  Fix issue where we would index into packages rather than rules;
        sometimes resulting in empty sets for collection references that had at
        least some dynamic part in them.

 -  0.7.1 (2019-12-25)
     *  Extend `%v` formatting in `sprintf` to work for objects, lists and sets.

 -  0.7.0 (2019-12-19)
     *  Change the return type of set() to set{unknown}.
     *  Add `--input` option to `fregot repl`.
     *  Add support for loading JSON/YAML files as data.
     *  Use a tree datastructure to store rules, fix Value.

        This is a huge refactoring that changes the following things:

         -  We now store rules in a tree structure (see `Fregot.Tree`) rather
            than having a collection of packages with rules.
         -  The evaluation distinguishes between `Value` (a grounded value) and
            `Mu` (a *M*aybe *u*ngrounded value), which allows us to reify
            packages.
         -  References into packages are extended, allowing us to e.g. iterate
            over all packages under a prefix.
         -  Improved dependency tracking for dynamic references to rules.

 -  0.6.0 (2019-12-14)
     *  Add support for raw strings.

 -  0.5.0 (2019-12-09)
     *  Add a type checking phase using flow analysis.
     *  Add the `:type` command to the REPL.

 -  0.4.4 (2019-11-18)
     *  Minor README improvements.
     *  Allow importing `input.` paths.
     *  Improve error when `package` declaration at the start of a file is
        missing.

 -  0.4.3 (2019-11-16)
     *  Add `is_set` and `is_boolean` builtin functions.

 -  0.4.2 (2019-11-14)
     *  Fixes an issue where depth-first iteration over collection rules would
        enumerate certain elements more than once.
     *  Improve caching by also keeping partially enumerated collections around
        and when a regular "exists" query is used, we will now visit the cached
        elements of the collection first to check for hits.
     *  Fix calculation of names used in rules.  This could possibly cause
        issues where the dependencies of a rule were calculated incorrectly,
        causing fregot to throw a renamer error.

 -  0.4.1 (2019-11-06)
     *  Allow YAML input documents.

 -  0.4.0 (2019-11-01)
     *  Re-license to Apache-2.0
     *  The `fregot repl` and `fregot eval` now take queries, not expressions
     *  Fix issues with cache during debugging
     *  Make `:reload` reload all files rather than just the file that was last
        loaded
     *  Add a `--watch` flag to `fregot repl` to watch file changes
     *  Add a `:watch` metacommand in the REPL to watch expressions or other
        metacommands
     *  Allow `:open pkg` as well as `:open data.pkg`
     *  Allow `:break data.pkg.rule` as well as `:break pkg.rule`

 -  0.3.0 (2019-10-11)
     *  Add support for `some` keyword
