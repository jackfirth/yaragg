#lang racket/base


(require racket/contract/base)


(provide
 (contract-out
  [earley-parser (-> context-free-grammar? parser?)]))


(require racket/contract
         racket/match
         racket/set
         racket/stream
         racket/struct
         rebellion/collection/vector
         rebellion/private/guarded-block
         yaragg/base/derivation
         yaragg/base/grammar
         yaragg/base/token
         yaragg/parser
         (submod yaragg/parser private))


(module+ test
  (require (submod "..")
           rackunit))


;@----------------------------------------------------------------------------------------------------


(define (earley-parser grammar)
  (make-parser #:datum-function (λ (tokens) (earley-parse-datum grammar tokens))
               #:syntax-function (λ (tokens) (earley-parse-syntax grammar tokens))))


;; The hash keys are sppf-labels and the values are a list of sppf-child-pairs
(struct sppf-forest (hash))


(define (make-sppf-forest)
  (sppf-forest (make-hash)))


(define (sppf-forest-add-node! forest label)
  (define h (sppf-forest-hash forest))
  (unless (hash-has-key? h label)
    (hash-set! h label '())))


(define (sppf-forest-add-child-pair! forest label #:left left-child #:right right-child)
  (define pair (sppf-child-pair left-child right-child))
  (hash-update! (sppf-forest-hash forest) label (λ (children) (cons pair children)) '()))


;; SPPF trees walk each rule down the left side, and each right child of the left spine corresponds to
;; the rule's components. See https://twitter.com/doitwithalambda/status/1510217894776348681 for a
;; diagram of the binarised parse tree.
(struct sppf-child-pair (left-child right-child) #:transparent)
(struct sppf-key () #:transparent)
(struct complete-sppf-key sppf-key (symbol input-start input-end) #:transparent)

(struct incomplete-sppf-key sppf-key (rule substitution-position input-start input-end)
  #:transparent)


(define (sppf-key-input-end key)
  (if (complete-sppf-key? key)
      (complete-sppf-key-input-end key)
      (incomplete-sppf-key-input-end key)))


(define (possible-children-lists forest key)
  (define hash (sppf-forest-hash forest))
  (let loop ([key key] [right-children '()])
    (guarded-block
     (guard key else
       (stream right-children))
     (match-define (list (sppf-child-pair left right) ...) (hash-ref hash key '()))
     (apply stream-append
            (for/list ([l (in-list left)]
                       [r (in-list right)])
              (loop l (cons r right-children)))))))


(define (cartesian-stream streams)

  (define (combine s1 s2)
    (for*/stream ([x (in-stream s1)]
                  [y (in-stream s2)])
      (cons x y)))

  (foldr combine (stream '()) streams))


(define (sppf-forest-derivations forest key tokens)
  (define hash (sppf-forest-hash forest))
  (let loop ([key key])
    (guarded-block
     (guard (complete-sppf-key? key) then
       (define tok (vector-ref tokens (complete-sppf-key-input-start key)))
       (stream (terminal-derivation (token-value tok))))
     (define label (context-free-production-rule-label (incomplete-sppf-key-rule key)))
     (define possible-children (possible-children-lists forest key))
     (for*/stream ([children (in-stream possible-children)]
                   [processed-children (in-stream (cartesian-stream (map loop children)))])
       (nonterminal-derivation label processed-children)))))


(struct earley-state (rule substitution-position input-position key)
  #:transparent
  #:property prop:custom-print-quotable 'never
  #:methods gen:custom-write
  [(define write-proc
     (make-constructor-style-printer
      (λ (_) 'earley-state)
      (λ (this)
        (define rule (earley-state-rule this))
        (define substitution (context-free-production-rule-substitution rule))
        (define pos (earley-state-substitution-position this))
        (append (list (context-free-production-rule-nonterminal rule) '->)
                (for/list ([sym (in-vector substitution 0 pos)])
                  (if (terminal-symbol? sym)
                      (terminal-symbol-value sym)
                      (nonterminal-symbol-value sym)))
                (list '•)
                (for/list ([sym (in-vector substitution pos)])
                  (if (terminal-symbol? sym)
                      (terminal-symbol-value sym)
                      (nonterminal-symbol-value sym)))
                (list (earley-state-input-position this) (earley-state-key this))))))])


(define (initial-earley-states grammar)
  (for/set ([rule (grammar-start-rules grammar)])
    (earley-state rule 0 0 #false)))


(define (earley-state-represents-successful-parse? state grammar)
  (and (zero? (earley-state-input-position state))
       (equal? (context-free-production-rule-nonterminal (earley-state-rule state))
               (context-free-grammar-start-symbol grammar))))


(define (earley-parse-datum grammar token-sequence)
  (define tokens (sequence->vector token-sequence))
  (define token-count (vector-length tokens))
  (define position-count (add1 token-count))
  (define forest (make-sppf-forest))
  (define states (make-vector position-count (set)))
  (vector-set! states 0 (initial-earley-states grammar))
  (for ([k (in-range 0 position-count)])
    
    ;; Prediction and completion
    (define/guard (process-states unprocessed processed)
      (guard (set-empty? unprocessed) then
        processed)
      (define next (set-first unprocessed))
      
      (define added-states
        (guarded-block
         (guard (completed-state? next) then
           ;; find all states in S(j) of the form (X → α • Y β, j) and add (X → α Y • β, j)
           (define j (earley-state-input-position next))
           (define completed (context-free-production-rule-nonterminal (earley-state-rule next)))
           (define parent-states
             (if (equal? j k)
                 (set-union unprocessed processed)
                 (vector-ref states j)))
           (completer-states completed parent-states (earley-state-key next) #:forest forest))
         (define symbol (earley-state-next-symbol next))
         (guard (nonterminal-symbol? symbol) else
           (set))
         (predictor-states grammar (nonterminal-symbol-value symbol) k)))
      
      (define new-unprocessed (set-subtract (set-remove added-states next) processed))
      (process-states (set-union (set-rest unprocessed) new-unprocessed) (set-add processed next)))

    (define processed (process-states (vector-ref states k) (set)))
    (vector-set! states k processed)
    (unless (equal? k token-count)
      (define next-states (scanner-states processed k (vector-ref tokens k) #:forest forest))
      (vector-set! states (add1 k) next-states)))

  (define last-state-set (vector-ref states (sub1 position-count)))
  (for/set ([s (in-set last-state-set)]
            #:when (earley-state-represents-successful-parse? s grammar)
            [derivation (in-stream (sppf-forest-derivations forest (earley-state-key s) tokens))])
    derivation))


(define (completed-state? state)
  (match-define (earley-state rule substitution-position _ _) state)
  (equal? substitution-position
          (vector-length (context-free-production-rule-substitution rule))))


(define/contract (earley-state-next-symbol state)
  (-> (and/c earley-state? (not/c completed-state?)) grammar-symbol?)
  (match-define (earley-state rule substitution-position _ _) state)
  (vector-ref (context-free-production-rule-substitution rule) substitution-position))


(define (earley-state-advance-substitution state #:key key)
  (match-define (earley-state rule substitution-position input-position _) state)
  (earley-state rule (add1 substitution-position) input-position key))


(define (completer-states completed-nonterminal states completed-key #:forest forest)
  (define expected (nonterminal-symbol completed-nonterminal))
  (for/set ([s (in-set states)]
            #:when (equal? (earley-state-next-symbol s) expected))
    (define rule (earley-state-rule s))
    (define start (earley-state-input-position s))
    (define end (sppf-key-input-end completed-key))
    (define old-key (earley-state-key s))
    (define new-key
      (incomplete-sppf-key rule (add1 (earley-state-substitution-position s)) start end))
    (sppf-forest-add-child-pair! forest new-key #:left old-key #:right completed-key)
    (earley-state-advance-substitution s #:key new-key)))


(define (predictor-states grammar nonterminal k)
  ;; add (Y → • γ, k) for every production in the grammar with Y on the left-hand side
  (for/set ([rule (in-vector (context-free-grammar-rules grammar))]
            #:when (equal? (context-free-production-rule-nonterminal rule) nonterminal))
    (earley-state rule 0 k #false)))


(define (scanner-states states k next-token #:forest forest)
  (define expected (terminal-symbol (token-type next-token)))
  (for/set ([s (in-set states)]
            #:when (not (completed-state? s))
            #:when (equal? (earley-state-next-symbol s) expected))
    (define rule (earley-state-rule s))
    (define start (earley-state-input-position s))
    (define end (add1 k))
    (define old-key (earley-state-key s))
    (define new-key
      (incomplete-sppf-key rule (add1 (earley-state-substitution-position s)) start end))
    (define scanned-key (complete-sppf-key expected k end))
    (sppf-forest-add-child-pair! forest new-key #:left old-key #:right scanned-key)
    (earley-state-advance-substitution s #:key new-key)))


(define (earley-parse-syntax grammar token-sequence)
  (define tokens
    (for/vector ([t token-sequence])
      (token (syntax-token-type t) t)))
  (for/set ([derivation (in-set (earley-parse-datum grammar tokens))])
    (parser-derivation->syntax derivation)))


(module+ test
  (test-case "earley-parser integration test"

    ;; Grammar and input taken from https://en.wikipedia.org/wiki/Earley_parser#Example

    (test-case "datum parser"
      (define P-rule (make-rule #:symbol 'P #:label 'P #:substitution (list (nonterminal-symbol 'S))))
      (define S-rule0
        (make-rule
         #:symbol 'S
         #:label 'S0
         #:substitution (list (nonterminal-symbol 'S) (terminal-symbol '+) (nonterminal-symbol 'M))))
      (define S-rule1
        (make-rule #:symbol 'S #:label 'S1 #:substitution (list (nonterminal-symbol 'M))))
      (define M-rule0
        (make-rule
         #:symbol 'M
         #:label 'M0
         #:substitution (list (nonterminal-symbol 'M) (terminal-symbol '*) (nonterminal-symbol 'T))))
      (define M-rule1
        (make-rule #:symbol 'M #:label 'M1 #:substitution (list (nonterminal-symbol 'T))))
      (define T-rule
        (make-rule #:symbol 'T #:label 'T #:substitution (list (terminal-symbol 'number))))
      (define arithmetic-grammar
        (make-grammar #:rules (list P-rule S-rule0 S-rule1 M-rule0 M-rule1 T-rule) #:start-symbol 'P))
      (define input-tokens
        (list
         (token 'number 2) (token '+ 'plus) (token 'number 3) (token '* 'times) (token 'number 4)))
      (define parser (earley-parser arithmetic-grammar))
      (define expected-arithmetic-parse-tree
        (parser-derivation
         'P
         (parser-derivation
          'S0
          (parser-derivation 'S1 (parser-derivation 'M1 (parser-derivation 'T (parser-derivation 2))))
          (parser-derivation 'plus)
          (parser-derivation
           'M0
           (parser-derivation 'M1 (parser-derivation 'T (parser-derivation 3)))
           (parser-derivation 'times)
           (parser-derivation 'T (parser-derivation 4))))))
    
      (check-equal? (parse-datum parser input-tokens) expected-arithmetic-parse-tree))

    (test-case "syntax parser"
      (define P-rule
        (make-rule
         #:symbol 'P #:label (syntax-label 'P) #:substitution (list (nonterminal-symbol 'S))))

      (define S-rule0
        (make-rule
         #:symbol 'S
         #:label (syntax-label 'S0)
         #:substitution (list (nonterminal-symbol 'S) (terminal-symbol '+) (nonterminal-symbol 'M))))

      (define S-rule1
        (make-rule
         #:symbol 'S #:label (syntax-label 'S1) #:substitution (list (nonterminal-symbol 'M))))

      (define M-rule0
        (make-rule
         #:symbol 'M
         #:label (syntax-label 'M0)
         #:substitution (list (nonterminal-symbol 'M) (terminal-symbol '*) (nonterminal-symbol 'T))))

      (define M-rule1
        (make-rule
         #:symbol 'M #:label (syntax-label 'M1) #:substitution (list (nonterminal-symbol 'T))))

      (define T-rule
        (make-rule
         #:symbol 'T #:label (syntax-label 'T) #:substitution (list (terminal-symbol 'number))))

      (define arithmetic-grammar
        (make-grammar #:rules (list P-rule S-rule0 S-rule1 M-rule0 M-rule1 T-rule) #:start-symbol 'P))


      (define input-tokens
        (list
         (syntax-token 'number 2 #:position 1 #:span 1)
         (syntax-token '+ #:position 2 #:span 1)
         (syntax-token 'number 3 #:position 3 #:span 1)
         (syntax-token '* #:position 4 #:span 1)
         (syntax-token 'number 4 #:position 5 #:span 1)))

      (define parser (earley-parser arithmetic-grammar))

      (check-equal? (syntax->datum (parse-syntax parser input-tokens))
                    '(P (S0 (S1 (M1 (T 2))) + (M0 (M1 (T 3)) * (T 4))))))))