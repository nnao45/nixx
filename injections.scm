; ~/.config/nvim/after/queries/nix/injections.scm
; Highlight bash inside  nixx.sh '' ... ''  (and nixx.task ... (nixx.sh '' ... '')).
; extends

; sh '' ... ''  — match an indented string that is the argument to `sh`
(apply_expression
  function: [
    (variable_expression name: (identifier) @_fn (#eq? @_fn "sh"))
    (select_expression
      attrpath: (attrpath (attr_name) @_attr (#eq? @_attr "sh")))
  ]
  argument: (indented_string_expression) @injection.content
  (#set! injection.language "bash"))
