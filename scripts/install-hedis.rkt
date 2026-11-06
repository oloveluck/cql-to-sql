#lang racket/base

;;; install-hedis.rkt — make NCQA's HEDIS core IG package usable by SUSHI and by fsh.
;;;
;;; The package was uploaded as an uncompressed tar (`ncqa.hedis.core.main.v2025-2025.1.0.tar`, at
;;; the repo root). This writes it where each tool looks:
;;; - SUSHI: its package cache, `~/.fhir/packages/<id>#<version>/package/…`; the registry has no
;;;   copy, so SUSHI uses this one (and fetches the package's public dependencies itself);
;;; - fsh: a gzipped `<id>-<version>.tgz` in `vendor/packages/` (gitignored), which the scenario
;;;   test puts in fsh's `current-package-directories`. This copy is REPACKAGED with the usual file
;;;   names: NCQA names its files `hedis-core-patient.json`, `ext-coverage.lti.json`, while the
;;;   family's package index (fhir/sd/sd-index) finds conformance resources only as
;;;   `package/<resourceType>-<id>.json`, and examples only under `package/example/`; with NCQA's
;;;   names fsh and the validator would not see a single HEDIS profile (and validation would pass by
;;;   failing open). The contents are unchanged; the tar in the repo and SUSHI's cache keep NCQA's
;;;   layout. The package's dependencies, once a SUSHI
;;;   build has fetched them into its cache (run `sushi build scenarios/bcse` once), are packed
;;;   there as .tgz too, so fsh resolves the same packages SUSHI does.
;;;
;;;   racket scripts/install-hedis.rkt [path/to/package.tar]

(require racket/file
         racket/path
         file/tar
         racket/runtime-path
         json
         file/untar
         file/gzip)

(define-runtime-path repo "..")

;; package-id+version : Path -> (values String String)   from the tar's package/package.json
(define (package-id+version tar)
  (define dir (make-temporary-directory "hedis-~a"))
  (untar tar #:dest dir #:filter (lambda (p . _) (equal? (path->string p) "package/package.json")))
  (define pj (call-with-input-file (build-path dir "package" "package.json") read-json))
  (delete-directory/files dir)
  (values (hash-ref pj 'name) (hash-ref pj 'version)))

;; repackage! : Path Path -> Path   the package at dir (an extracted package/ tree) as a .tgz whose
;; JSON files are named <resourceType>-<id>.json, examples under package/example/
(define (repackage! dir tgz)
  (define stage (make-temporary-directory "hedis-pkg-~a"))
  (define (copy-as! src dest-dir)
    (define js (call-with-input-file src read-json))
    (define name (if (and (hash? js) (hash-ref js 'resourceType #f) (hash-ref js 'id #f))
                     (format "~a-~a.json" (hash-ref js 'resourceType) (hash-ref js 'id))
                     (let-values ([(_d n _m) (split-path src)]) (path->string n))))
    (make-directory* dest-dir)
    (copy-file src (build-path dest-dir name) #t))
  (define pkg (build-path dir "package"))
  (for ([f (directory-list pkg #:build? #t)])
    (cond
      [(and (file-exists? f) (regexp-match? #rx"[.]json$" (path->string f)))
       (if (regexp-match? #rx"package[.]json$" (path->string f))
           (begin (make-directory* (build-path stage "package")) (copy-file f (build-path stage "package" "package.json") #t))
           (copy-as! f (build-path stage "package")))]
      [(directory-exists? f)
       (for ([g (directory-list f #:build? #t)] #:when (regexp-match? #rx"[.]json$" (path->string g)))
         (copy-as! g (build-path stage "package" "example")))]))
  (when (file-exists? tgz) (delete-file tgz))
  (parameterize ([current-directory stage]) (tar-gzip tgz "package"))
  (delete-directory/files stage)
  tgz)

;; pack-cached! : Path id version Path -> (or Path #f)   SUSHI's cached <id>#<version> as a .tgz
(define (pack-cached! cache-root id version out-dir)
  (define dir (build-path cache-root (format "~a#~a" id version)))
  (and (directory-exists? (build-path dir "package"))
       (let ([tgz (build-path out-dir (format "~a-~a.tgz" id version))])
         (when (file-exists? tgz) (delete-file tgz))     ; rerunnable
         (parameterize ([current-directory dir])
           (tar-gzip tgz "package"))
         tgz)))

(module+ main
  (define tar (simplify-path
               (let ([args (current-command-line-arguments)])
                 (if (positive? (vector-length args))
                     (path->complete-path (vector-ref args 0))
                     (build-path repo "ncqa.hedis.core.main.v2025-2025.1.0.tar")))))
  (unless (file-exists? tar) (raise-user-error 'install-hedis "no package tar at ~a" tar))
  (define-values (id version) (package-id+version tar))
  ;; SUSHI's cache
  (define cache (build-path (find-system-path 'home-dir) ".fhir" "packages" (format "~a#~a" id version)))
  (when (directory-exists? cache) (delete-directory/files cache))
  (make-directory* cache)
  (untar tar #:dest cache)
  (printf "SUSHI cache: ~a (~a files)\n" cache (length (directory-list (build-path cache "package"))))
  ;; fsh's package directory
  (define out-dir (build-path repo "vendor" "packages"))
  (make-directory* out-dir)
  (define tgz (repackage! cache (build-path out-dir (format "~a-~a.tgz" id version))))
  (printf "fsh package:  ~a (repackaged with <resourceType>-<id>.json names)\n" (simplify-path tgz))
  ;; its dependencies, from SUSHI's cache (the core package fsh takes from fhir-spec)
  (define deps (let ([pj (call-with-input-file (build-path cache "package" "package.json") read-json)])
                 (for/list ([(k v) (in-hash (hash-ref pj 'dependencies (hasheq)))]
                            #:unless (regexp-match? #rx"^hl7[.]fhir[.]r[0-9]+[.]core$" (symbol->string k)))
                   (cons (symbol->string k) v))))
  (define cache-root (build-path (find-system-path 'home-dir) ".fhir" "packages"))
  (for ([d (sort deps string<? #:key car)])
    (define t (pack-cached! cache-root (car d) (cdr d) out-dir))
    (if t
        (printf "dependency:   ~a\n" (simplify-path t))
        (printf "dependency:   ~a#~a is not in SUSHI's cache yet: run `sushi build scenarios/bcse`, then this again\n" (car d) (cdr d)))))
