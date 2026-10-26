locals_without_parens = [
  defnoul: 1,
  defnoul: 2,
  defnoul: 3,
  defchoice: 2,
  defchoice: 3,
  defscore: 2,
  defscore: 3,
  defjev: 2,
  defalias: 2,
  noul: 1,
  noul: 2,
  noul: 3,
  choice: 2,
  choice: 3,
  score: 2,
  score: 3
]

[
  inputs: ["{mix,.formatter}.exs", "{config,lib,test}/**/*.{ex,exs}"],
  locals_without_parens: locals_without_parens,
  export: [
    locals_without_parens: locals_without_parens
  ]
]
