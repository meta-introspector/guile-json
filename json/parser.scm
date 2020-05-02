;;; (json parser) --- Guile JSON implementation.

;; Copyright (C) 2013-2020 Aleix Conchillo Flaque <aconchillo@gmail.com>
;;
;; This file is part of guile-json.
;;
;; guile-json is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation; either version 3 of the License, or
;; (at your option) any later version.
;;
;; guile-json is distributed in the hope that it will be useful, but
;; WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU
;; General Public License for more details.
;;
;; You should have received a copy of the GNU General Public License
;; along with guile-json. If not, see https://www.gnu.org/licenses/.

;;; Commentary:

;; JSON module for Guile

;;; Code:

(define-module (json parser)
  #:use-module (ice-9 match)
  #:use-module (ice-9 textual-ports)
  #:use-module (srfi srfi-9)
  #:export (json->scm
            json-string->scm
            json-parser?
            json-parser-port))

;;
;; Parser record and read helpers
;;

(define-record-type json-parser
  (make-json-parser port)
  json-parser?
  (port json-parser-port))

(define-syntax-rule (parser-peek-char parser)
  (peek-char (json-parser-port parser)))

(define-syntax-rule (parser-read-char parser)
  (read-char (json-parser-port parser)))

;;
;; Miscellaneuos helpers
;;

(define (json-exception parser)
  (throw 'json-invalid parser))

(define (digit? c)
  (case c
    ((#\0 #\1 #\2 #\3 #\4 #\5 #\6 #\7 #\8 #\9) #t)
    (else #f)))

(define (whitespace? c)
  (case c
    ((#\ht #\lf #\cr #\sp) #t)
    (else #f)))

(define (skip-whitespaces parser)
  (match (parser-peek-char parser)
    ((? eof-object?) *unspecified*)
    ((? whitespace?)
     (parser-read-char parser)
     (skip-whitespaces parser))
    (_ *unspecified*)))

(define (expect-string parser expected return)
  (let loop ((n 0))
    (cond
     ((= n (string-length expected)) return)
     ((eqv? (parser-read-char parser) (string-ref expected n))
      (loop (+ n 1)))
     (else (json-exception parser)))))

(define (expect-delimiter parser delimiter)
  (match (parser-read-char parser)
    ((? eof-object?) (json-exception parser))
    (ch (unless (eqv? ch delimiter) (json-exception parser)))))

;;
;; Number parsing helpers
;;

;; Read + or -. If something different is found, return empty string.
(define (read-sign parser string-port)
  (match (parser-peek-char parser)
    ((or #\+ #\-) (put-char string-port (parser-read-char parser)))
    (_ *unspecified*)))

;; Read digits [0..9].
(define (read-digits parser string-port)
  (match (parser-peek-char parser)
    ((? eof-object?) *unspecified*)
    ((? digit?)
     (put-char string-port (parser-read-char parser))
     (read-digits parser string-port))
    (_ *unspecified*)))

(define (read-exponent parser string-port)
  (match (parser-peek-char parser)
    ((or #\e #\E)
     (parser-read-char parser)
     (put-char string-port #\e)
     (read-sign parser string-port)
     (read-digits parser string-port))
    (_ *unspecified*)))

(define (read-fraction parser string-port)
  (match (parser-peek-char parser)
    (#\.
     (parser-read-char parser)
     (put-char string-port #\.)
     (read-digits parser string-port))
    (_ *unspecified*)))

(define (read-positive-number parser string-port)
  (read-digits parser string-port)
  (read-fraction parser string-port)
  (read-exponent parser string-port))

(define (read-number parser string-port)
  (match (parser-peek-char parser)
    ((? eof-object?) (json-exception parser))
    (#\-
     (parser-read-char parser)
     (put-char string-port #\-)
     (read-positive-number parser string-port))
    (#\0
     (parser-read-char parser)
     (put-char string-port #\0)
     (read-fraction parser string-port)
     (read-exponent parser string-port))
    ((? digit?)
     (read-positive-number parser string-port))
    (_ (json-exception parser))))

(define (json-read-number parser)
  (string->number
   (call-with-output-string
     (lambda (string-port) (read-number parser string-port)))))

;;
;; Object parsing helpers
;;

(define (read-pair parser)
  ;; Read key.
  (let ((key (json-read-string parser)))
    (skip-whitespaces parser)
    (match (parser-peek-char parser)
      ((? eof-object?) (json-exception parser))
      ;; Skip colon and read value.
      (#\:
       (parser-read-char parser)
       (cons key (json-read parser)))
      (_ (json-exception parser)))))

(define (json-read-object parser)
  (expect-delimiter parser #\{)
  (let loop ((pairs '()) (added #t))
    (skip-whitespaces parser)
    (match (parser-peek-char parser)
      ((? eof-object?) (json-exception parser))
      ;; End of object.
      (#\}
       (parser-read-char parser)
       (cond
        (added pairs)
        (else (json-exception parser))))
      ;; Read one pair and continue.
      (#\"
       (let ((pair (read-pair parser)))
         (loop (cons pair pairs) #t)))
      ;; Skip comma and read more pairs.
      (#\,
       (parser-read-char parser)
       (cond
        (added (loop pairs #f))
        (else (json-exception parser))))
      ;; Invalid object.
      (_ (json-exception parser)))))

;;
;; Array parsing helpers
;;

(define (json-read-array parser)
  (expect-delimiter parser #\[)
  (let loop ((values '()) (added #t))
    (skip-whitespaces parser)
    (match (parser-peek-char parser)
      ((? eof-object?) (json-exception parser))
      ;; Handle comma (make sure we added an element).
      (#\,
       (parser-read-char parser)
       (cond
        (added (loop values #f))
        (else (json-exception parser))))
      ;; End of array (make sure we added an element).
      (#\]
       (parser-read-char parser)
       (cond
        (added (list->vector values))
        (else (json-exception parser))))
      ;; This can be any JSON object.
      (_
       (let ((value (json-read parser)))
         (loop (append values (list value)) #t))))))

;;
;; String parsing helpers
;;

(define (read-hex-digit->integer parser)
  (match (parser-read-char parser)
    (#\0 0)
    (#\1 1)
    (#\2 2)
    (#\3 3)
    (#\4 4)
    (#\5 5)
    (#\6 6)
    (#\7 7)
    (#\8 8)
    (#\9 9)
    ((or #\A #\a) 10)
    ((or #\B #\b) 11)
    ((or #\C #\c) 12)
    ((or #\D #\d) 13)
    ((or #\E #\e) 14)
    ((or #\F #\f) 15)
    (_ (json-exception parser))))

;; Characters in Guile match the JSON representation so we just need to parse
;; the hexadecimal values into an integer.
;;
;;     codepoint = 16^3 * ch + 16^2 * ch + 16 * ch + ch
;;
;; https://www.gnu.org/software/guile/manual/html_node/Characters.html
(define (read-unicode-char parser)
  (integer->char
   (+ (* 4096 (read-hex-digit->integer parser))
      (* 256 (read-hex-digit->integer parser))
      (* 16 (read-hex-digit->integer parser))
      (read-hex-digit->integer parser))))

(define (read-control-char parser)
  (match (parser-read-char parser)
    (#\" #\")
    (#\\ #\\)
    (#\/ #\/)
    (#\b #\bs)
    (#\f #\ff)
    (#\n #\lf)
    (#\r #\cr)
    (#\t #\ht)
    (#\u (read-unicode-char parser))
    (_ (json-exception parser))))

(define (json-read-string parser)
  (expect-delimiter parser #\")
  (let loop ((chars '()))
    (match (parser-read-char parser)
      ((? eof-object?) (json-exception parser))
      (#\" (reverse-list->string chars))
      (#\\ (loop (cons (read-control-char parser) chars)))
      (ch (loop (cons ch chars))))))

;;
;; Booleans and null parsing helpers
;;

(define (json-read-true parser)
  (expect-string parser "true" #t))

(define (json-read-false parser)
  (expect-string parser "false" #f))

(define (json-read-null parser)
  (expect-string parser "null" #nil))

;;
;; Main parser functions
;;

(define (json-read parser)
  (skip-whitespaces parser)
  (match (parser-peek-char parser)
    ;; If we reach the end we might have an incomplete document.
    ((? eof-object?) (json-exception parser))
    ;; Read JSON values.
    (#\t (json-read-true parser))
    (#\f (json-read-false parser))
    (#\n (json-read-null parser))
    (#\{ (json-read-object parser))
    (#\[ (json-read-array parser))
    (#\" (json-read-string parser))
    ;; Anything else should be a number.
    (_ (json-read-number parser))))

;;
;; Public procedures
;;

(define* (json->scm #:optional (port (current-input-port)))
  "Parse a JSON document into native. Takes one optional argument,
@var{port}, which defaults to the current input port from where the JSON
document is read."
  (let* ((parser (make-json-parser port))
         (value (json-read parser)))
    ;; Skip any trailing whitespaces.
    (skip-whitespaces parser)
    (cond
     ;; If we reach the end the parsing succeeded.
     ((eof-object? (parser-peek-char parser)) value)
     ;; If there's anything else other than the end, parser fails.
     (else (json-exception parser)))))

(define* (json-string->scm str)
  "Parse a JSON document into native. Takes a string argument,
@var{str}, that contains the JSON document."
  (call-with-input-string str (lambda (p) (json->scm p))))

;;; (json parser) ends here
