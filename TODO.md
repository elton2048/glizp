TODO
---

This is a TODO reference. Apart from Lisp Interpreter part which based on https://github.com/kanaka/mal/blob/master/process/guide.md, there are different parts of work shall be done for this project.

## Lisp Interpreter

The base of this project, largely based on https://github.com/kanaka/mal/blob/master/process/guide.md which divids the inplementation steps.

### Step 0
  - [x] Add the 4 trivial functions `READ`, `EVAL`, `PRINT`, and `rep` (6683c1f)
  - [x] Add a main loop that repeatedly prints a prompt (needs to be "user> " for later tests to pass), gets a line of input from the user, calls rep with that line of input, and then prints out the result from rep (6683c1f)
  - [x] Exit when send it an EOF (ofer Ctrl-D) (1e9c9bb)
  - [ ] Add full line editing and command history support to your interpreter REPL (56f7774/dbd2426/b2eb930; Most line editing features are not implemented, only very basic functions like Enter to send, send EOF marker are done. Check https://en.wikipedia.org/wiki/GNU_Readline for a complete list. Command history is done for getting prior or next command)

### Step 1
  - [x] Add a function `read_str` in reader.qx. This function will call tokenize and then create a new Reader object instance with the tokens. Then it will call `read_form` with the Reader instance (c1cc4e5)
  - [x] Add a function `tokenize` in reader.qx. This function will take a single string and return an array/list of all the tokens (strings) in it. The following regular expression (PCRE) will match all mal tokens (c1cc4e5)
  - [x] Add the function `read_form` to reader.qx (c1cc4e5)
  - [x] Add the function `read_list` to reader.qx (c1cc4e5)
  - [x] Add the function `read_atom` to reader.qx (c1cc4e5)
  - [x] Add the function `pr_str` in printer.qx. To support printing the string representation of a mal data structure (c1cc4e5)
  - [ ] Add support for the other basic data type to your reader and printer functions: string, nil, true, and false
  - [x] Add error checking to your reader functions to make sure parens are properly matched (c1cc4e5)
  - [ ] Add support for reader macros which are forms that are transformed into other forms during the read phase
  - [ ] Add support for the other mal types: keyword, vector, hash-map
  - [ ] Add comment support to your reader

## Shell
  - [x] InputEvent key input design (0c81e0c)
  - [ ] Add cursor support
  - [ ] Test cases support

## Terminal

Frontend layer for display purpose. This is expected to be generalize as frontend which has common interface to support using different engine for UI rendering.

  - [ ] Separate out from `Shell` part (#12)

## Miscellaneous
  - [ ] Using tree-sitter for language parser
  - [ ] Keymap feature
