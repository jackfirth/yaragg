#lang info


(define collection "yaragg")


(define scribblings
  '(("yaragg.scrbl" (multi-page) (parsing-library))
    ("yaragg-parser-tools.scrbl" (multi-page) (parsing-library))))


(define deps '(["base" #:version "6.3"]
               "rackunit-lib"
               "syntax-color-lib"))


(define build-deps '("at-exp-lib"
                     "racket-doc"
                     "scribble-lib"
                     "syntax-color-doc"))


(define test-omit-paths '("examples/simple-line-drawing/examples/letter-i.rkt"))