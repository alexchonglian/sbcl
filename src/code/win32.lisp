;;;; This file contains Win32 support routines that SBCL needs to
;;;; implement itself, in addition to those that apply to Win32 in
;;;; unix.lisp.  In theory, some of these functions might someday be
;;;; useful to the end user.

;;;; This software is part of the SBCL system. See the README file for
;;;; more information.
;;;;
;;;; This software is derived from the CMU CL system, which was
;;;; written at Carnegie Mellon University and released into the
;;;; public domain. The software is in the public domain and is
;;;; provided with absolutely no warranty. See the COPYING and CREDITS
;;;; files for more information.

(in-package "SB!WIN32")

;;; Alien definitions for commonly used Win32 types.  Woe unto whoever
;;; tries to untangle this someday for 64-bit Windows.
;;;
;;; FIXME: There used to be many more here, which are now groveled,
;;; but groveling HANDLE makes it unsigned, which currently breaks the
;;; build. --NS 2006-06-18
(define-alien-type handle int-ptr)

(define-alien-type lispbool (boolean 32))

(define-alien-type system-string
                   #!-sb-unicode c-string
                   #!+sb-unicode (c-string :external-format :ucs-2))

(define-alien-type tchar #!-sb-unicode char
                         #!+sb-unicode (unsigned 16))

(defconstant default-environment-length 1024)

;;; HANDLEs are actually pointers, but an invalid handle is -1 cast
;;; to a pointer.
(defconstant invalid-handle -1)

(defconstant file-attribute-readonly #x1)
(defconstant file-attribute-hidden #x2)
(defconstant file-attribute-system #x4)
(defconstant file-attribute-directory #x10)
(defconstant file-attribute-archive #x20)
(defconstant file-attribute-device #x40)
(defconstant file-attribute-normal #x80)
(defconstant file-attribute-temporary #x100)
(defconstant file-attribute-sparse #x200)
(defconstant file-attribute-reparse-point #x400)
(defconstant file-attribute-reparse-compressed #x800)
(defconstant file-attribute-reparse-offline #x1000)
(defconstant file-attribute-not-content-indexed #x2000)
(defconstant file-attribute-encrypted #x4000)

(defconstant file-flag-overlapped #x40000000)
(defconstant file-flag-sequential-scan #x8000000)

;; Possible results of GetFileType.
(defconstant file-type-disk 1)
(defconstant file-type-char 2)
(defconstant file-type-pipe 3)
(defconstant file-type-remote 4)
(defconstant file-type-unknown 0)

(defconstant invalid-file-attributes (mod -1 (ash 1 32)))

;;;; File Type Introspection by handle
(define-alien-routine ("GetFileType" get-file-type) dword
  (handle handle))

;;;; Error Handling

;;; Retrieve the calling thread's last-error code value.  The
;;; last-error code is maintained on a per-thread basis.
(define-alien-routine ("GetLastError" get-last-error) dword)

;;;; File Handles

;;; Historically, SBCL on Windows used CRT (lowio) file descriptors,
;;; unlike other Lisps. They really help to minimize required effort
;;; for porting Unix-specific software, at least to the level that it
;;; mostly works most of the time.
;;;
;;; Alastair Bridgewater recommended to switch away from CRT
;;; descriptors, and Anton Kovalenko thinks it's the time to heed his
;;; advice. I see that SBCL for Windows needs much more effort in the
;;; area of OS IO abstractions and the like; using or leaving lowio
;;; FDs doesn't change the big picture so much.
;;;
;;; Lowio layer, in exchange for `semi-automatic almost-portability',
;;; brings some significant problems, which a grown-up cross-platform
;;; CL implementation shouldn't have. Therefore, as its benefits
;;; become negligible, it's a good reason to throw it away.
;;;
;;;  -- comment from AK's branch

;;; For a few more releases, let's preserve old functions (now
;;; implemented as identity) for user code which might have had to peek
;;; into our internals in past versions when we hadn't been using
;;; handles yet. -- DFL, 2012
(defun get-osfhandle (fd) fd)
(defun open-osfhandle (handle flags) (declare (ignore flags)) handle)

;;; Get the operating system handle for a C file descriptor.  Returns
;;; INVALID-HANDLE on failure.
(define-alien-routine ("_get_osfhandle" real-get-osfhandle) handle
  (fd int))

(define-alien-routine ("_close" real-crt-close) int
  (fd int))

;;; Read data from a file handle into a buffer.  This may be used
;;; synchronously or with "overlapped" (asynchronous) I/O.
(define-alien-routine ("ReadFile" read-file) bool
  (file handle)
  (buffer (* t))
  (bytes-to-read dword)
  (bytes-read (* dword))
  (overlapped (* t)))

;;; Write data from a buffer to a file handle.  This may be used
;;; synchronously  or with "overlapped" (asynchronous) I/O.
(define-alien-routine ("WriteFile" write-file) bool
  (file handle)
  (buffer (* t))
  (bytes-to-write dword)
  (bytes-written (* dword))
  (overlapped (* t)))

;;; Copy data from a named or anonymous pipe into a buffer without
;;; removing it from the pipe.  BUFFER, BYTES-READ, BYTES-AVAIL, and
;;; BYTES-LEFT-THIS-MESSAGE may be NULL if no data is to be read.
;;; Return TRUE on success, FALSE on failure.
(define-alien-routine ("PeekNamedPipe" peek-named-pipe) bool
  (pipe handle)
  (buffer (* t))
  (buffer-size dword)
  (bytes-read (* dword))
  (bytes-avail (* dword))
  (bytes-left-this-message (* dword)))

;;; Flush the console input buffer if HANDLE is a console handle.
;;; Returns true on success, false if the handle does not refer to a
;;; console.
(define-alien-routine ("FlushConsoleInputBuffer" flush-console-input-buffer) bool
  (handle handle))

;;; Read data from the console input buffer without removing it,
;;; without blocking.  Buffer should be large enough for LENGTH *
;;; INPUT-RECORD-SIZE bytes.
(define-alien-routine ("PeekConsoleInputA" peek-console-input) bool
  (handle handle)
  (buffer (* t))
  (length dword)
  (nevents (* dword)))

(define-alien-routine ("socket_input_available" socket-input-available) int
  (socket handle))

;;; Listen for input on a Windows file handle.  Unlike UNIX, there
;;; isn't a unified interface to do this---we have to know what sort
;;; of handle we have.  Of course, there's no way to actually
;;; introspect it, so we have to try various things until we find
;;; something that works.  Returns true if there could be input
;;; available, or false if there is not.
(defun handle-listen (handle)
  (with-alien ((avail dword)
               (buf (array char #.input-record-size)))
    (when
        ;; Make use of the fact that console handles are technically no
        ;; real handles, and unlike those, have these bits set:
        (= 3 (logand 3 handle))
      (return-from handle-listen
        (alien-funcall (extern-alien "win32_tty_listen"
                                     (function boolean handle))
                       handle)))
    (unless (zerop (peek-named-pipe handle nil 0 nil (addr avail) nil))
      (return-from handle-listen (plusp avail)))
    (let ((res (socket-input-available handle)))
      (unless (zerop res)
        (return-from handle-listen (= res 1))))
    t))

;;; Listen for input on a C runtime file handle.  Returns true if
;;; there could be input available, or false if there is not.
(defun fd-listen (fd)
  (let ((handle (get-osfhandle fd)))
    (if handle
        (handle-listen handle)
        t)))

;;; Clear all available input from a file handle.
(defun handle-clear-input (handle)
  (flush-console-input-buffer handle)
  (with-alien ((buf (array char 1024))
               (count dword))
    (loop
     (unless (handle-listen handle)
       (return))
     (when (zerop (read-file handle (cast buf (* t)) 1024 (addr count) nil))
       (return))
     (when (< count 1024)
       (return)))))

;;; Clear all available input from a C runtime file handle.
(defun fd-clear-input (fd)
  (let ((handle (get-osfhandle fd)))
    (when handle
      (handle-clear-input handle))))

;;;; System Functions

#!-sb-thread
(define-alien-routine ("Sleep" millisleep) void
  (milliseconds dword))

#!+sb-thread
(defun sb!unix:nanosleep (sec nsec)
  (let ((*allow-with-interrupts* *interrupts-enabled*))
    (without-interrupts
      (let ((timer (sb!impl::os-create-wtimer)))
        (sb!impl::os-set-wtimer timer sec nsec)
        (unwind-protect
             (do () ((with-local-interrupts
                       (zerop (sb!impl::os-wait-for-wtimer timer)))))
          (sb!impl::os-close-wtimer timer))))))

(define-alien-routine ("win32_wait_object_or_signal" wait-object-or-signal)
    (signed 16)
  (handle handle))

#!+sb-unicode
(progn
  (defvar *ansi-codepage* nil)
  (defvar *oem-codepage* nil)
  (defvar *codepage-to-external-format* (make-hash-table)))

#!+sb-unicode
(dolist
    (cp '(;;037       IBM EBCDIC - U.S./Canada
          (437 :CP437) ;; OEM - United States
          ;;500       IBM EBCDIC - International
          ;;708       Arabic - ASMO 708
          ;;709       Arabic - ASMO 449+, BCON V4
          ;;710       Arabic - Transparent Arabic
          ;;720       Arabic - Transparent ASMO
          ;;737       OEM - Greek (formerly 437G)
          ;;775       OEM - Baltic
          (850 :CP850)     ;; OEM - Multilingual Latin I
          (852 :CP852)     ;; OEM - Latin II
          (855 :CP855)     ;; OEM - Cyrillic (primarily Russian)
          (857 :CP857)     ;; OEM - Turkish
          ;;858       OEM - Multilingual Latin I + Euro symbol
          (860 :CP860)     ;; OEM - Portuguese
          (861 :CP861)     ;; OEM - Icelandic
          (862 :CP862)     ;; OEM - Hebrew
          (863 :CP863)     ;; OEM - Canadian-French
          (864 :CP864)     ;; OEM - Arabic
          (865 :CP865)     ;; OEM - Nordic
          (866 :CP866)     ;; OEM - Russian
          (869 :CP869)     ;; OEM - Modern Greek
          ;;870       IBM EBCDIC - Multilingual/ROECE (Latin-2)
          (874 :CP874) ;; ANSI/OEM - Thai (same as 28605, ISO 8859-15)
          ;;875       IBM EBCDIC - Modern Greek
          (932 :CP932)     ;; ANSI/OEM - Japanese, Shift-JIS
          ;;936       ANSI/OEM - Simplified Chinese (PRC, Singapore)
          ;;949       ANSI/OEM - Korean (Unified Hangul Code)
          ;;950       ANSI/OEM - Traditional Chinese (Taiwan; Hong Kong SAR, PRC)
          ;;1026      IBM EBCDIC - Turkish (Latin-5)
          ;;1047      IBM EBCDIC - Latin 1/Open System
          ;;1140      IBM EBCDIC - U.S./Canada (037 + Euro symbol)
          ;;1141      IBM EBCDIC - Germany (20273 + Euro symbol)
          ;;1142      IBM EBCDIC - Denmark/Norway (20277 + Euro symbol)
          ;;1143      IBM EBCDIC - Finland/Sweden (20278 + Euro symbol)
          ;;1144      IBM EBCDIC - Italy (20280 + Euro symbol)
          ;;1145      IBM EBCDIC - Latin America/Spain (20284 + Euro symbol)
          ;;1146      IBM EBCDIC - United Kingdom (20285 + Euro symbol)
          ;;1147      IBM EBCDIC - France (20297 + Euro symbol)
          ;;1148      IBM EBCDIC - International (500 + Euro symbol)
          ;;1149      IBM EBCDIC - Icelandic (20871 + Euro symbol)
          (1200 :UCS-2LE)    ;; Unicode UCS-2 Little-Endian (BMP of ISO 10646)
          (1201 :UCS-2BE)    ;; Unicode UCS-2 Big-Endian
          (1250 :CP1250)     ;; ANSI - Central European
          (1251 :CP1251)     ;; ANSI - Cyrillic
          (1252 :CP1252)     ;; ANSI - Latin I
          (1253 :CP1253)     ;; ANSI - Greek
          (1254 :CP1254)     ;; ANSI - Turkish
          (1255 :CP1255)     ;; ANSI - Hebrew
          (1256 :CP1256)     ;; ANSI - Arabic
          (1257 :CP1257)     ;; ANSI - Baltic
          (1258 :CP1258)     ;; ANSI/OEM - Vietnamese
          ;;1361      Korean (Johab)
          ;;10000 MAC - Roman
          ;;10001     MAC - Japanese
          ;;10002     MAC - Traditional Chinese (Big5)
          ;;10003     MAC - Korean
          ;;10004     MAC - Arabic
          ;;10005     MAC - Hebrew
          ;;10006     MAC - Greek I
          (10007 :X-MAC-CYRILLIC) ;; MAC - Cyrillic
          ;;10008     MAC - Simplified Chinese (GB 2312)
          ;;10010     MAC - Romania
          ;;10017     MAC - Ukraine
          ;;10021     MAC - Thai
          ;;10029     MAC - Latin II
          ;;10079     MAC - Icelandic
          ;;10081     MAC - Turkish
          ;;10082     MAC - Croatia
          ;;12000     Unicode UCS-4 Little-Endian
          ;;12001     Unicode UCS-4 Big-Endian
          ;;20000     CNS - Taiwan
          ;;20001     TCA - Taiwan
          ;;20002     Eten - Taiwan
          ;;20003     IBM5550 - Taiwan
          ;;20004     TeleText - Taiwan
          ;;20005     Wang - Taiwan
          ;;20105     IA5 IRV International Alphabet No. 5 (7-bit)
          ;;20106     IA5 German (7-bit)
          ;;20107     IA5 Swedish (7-bit)
          ;;20108     IA5 Norwegian (7-bit)
          ;;20127     US-ASCII (7-bit)
          ;;20261     T.61
          ;;20269     ISO 6937 Non-Spacing Accent
          ;;20273     IBM EBCDIC - Germany
          ;;20277     IBM EBCDIC - Denmark/Norway
          ;;20278     IBM EBCDIC - Finland/Sweden
          ;;20280     IBM EBCDIC - Italy
          ;;20284     IBM EBCDIC - Latin America/Spain
          ;;20285     IBM EBCDIC - United Kingdom
          ;;20290     IBM EBCDIC - Japanese Katakana Extended
          ;;20297     IBM EBCDIC - France
          ;;20420     IBM EBCDIC - Arabic
          ;;20423     IBM EBCDIC - Greek
          ;;20424     IBM EBCDIC - Hebrew
          ;;20833     IBM EBCDIC - Korean Extended
          ;;20838     IBM EBCDIC - Thai
          (20866 :KOI8-R) ;; Russian - KOI8-R
          ;;20871     IBM EBCDIC - Icelandic
          ;;20880     IBM EBCDIC - Cyrillic (Russian)
          ;;20905     IBM EBCDIC - Turkish
          ;;20924     IBM EBCDIC - Latin-1/Open System (1047 + Euro symbol)
          ;;20932     JIS X 0208-1990 & 0121-1990
          ;;20936     Simplified Chinese (GB2312)
          ;;21025     IBM EBCDIC - Cyrillic (Serbian, Bulgarian)
          ;;21027     (deprecated)
          (21866 :KOI8-U)      ;; Ukrainian (KOI8-U)
          (28591 :LATIN-1)     ;; ISO 8859-1 Latin I
          (28592 :ISO-8859-2)  ;; ISO 8859-2 Central Europe
          (28593 :ISO-8859-3)  ;; ISO 8859-3 Latin 3
          (28594 :ISO-8859-4)  ;; ISO 8859-4 Baltic
          (28595 :ISO-8859-5)  ;; ISO 8859-5 Cyrillic
          (28596 :ISO-8859-6)  ;; ISO 8859-6 Arabic
          (28597 :ISO-8859-7)  ;; ISO 8859-7 Greek
          (28598 :ISO-8859-8)  ;; ISO 8859-8 Hebrew
          (28599 :ISO-8859-9)  ;; ISO 8859-9 Latin 5
          (28605 :LATIN-9)     ;; ISO 8859-15 Latin 9
          ;;29001     Europa 3
          (38598 :ISO-8859-8) ;; ISO 8859-8 Hebrew
          ;;50220     ISO 2022 Japanese with no halfwidth Katakana
          ;;50221     ISO 2022 Japanese with halfwidth Katakana
          ;;50222     ISO 2022 Japanese JIS X 0201-1989
          ;;50225     ISO 2022 Korean
          ;;50227     ISO 2022 Simplified Chinese
          ;;50229     ISO 2022 Traditional Chinese
          ;;50930     Japanese (Katakana) Extended
          ;;50931     US/Canada and Japanese
          ;;50933     Korean Extended and Korean
          ;;50935     Simplified Chinese Extended and Simplified Chinese
          ;;50936     Simplified Chinese
          ;;50937     US/Canada and Traditional Chinese
          ;;50939     Japanese (Latin) Extended and Japanese
          (51932 :EUC-JP) ;; EUC - Japanese
          ;;51936     EUC - Simplified Chinese
          ;;51949     EUC - Korean
          ;;51950     EUC - Traditional Chinese
          ;;52936     HZ-GB2312 Simplified Chinese
          ;;54936     Windows XP: GB18030 Simplified Chinese (4 Byte)
          ;;57002     ISCII Devanagari
          ;;57003     ISCII Bengali
          ;;57004     ISCII Tamil
          ;;57005     ISCII Telugu
          ;;57006     ISCII Assamese
          ;;57007     ISCII Oriya
          ;;57008     ISCII Kannada
          ;;57009     ISCII Malayalam
          ;;57010     ISCII Gujarati
          ;;57011     ISCII Punjabi
          ;;65000     Unicode UTF-7
          (65001 :UTF8))) ;; Unicode UTF-8
  (setf (gethash (car cp) *codepage-to-external-format*) (cadr cp)))

#!+sb-unicode
;; FIXME: Something odd here: why are these two #+SB-UNICODE, whereas
;; the console just behave differently?
(progn
  (declaim (ftype (function () keyword) ansi-codepage))
  (defun ansi-codepage ()
    (or *ansi-codepage*
        (setq *ansi-codepage*
              (gethash (alien-funcall (extern-alien "GetACP" (function UINT)))
                       *codepage-to-external-format*
                       :latin-1))))

  (declaim (ftype (function () keyword) oem-codepage))
  (defun oem-codepage ()
    (or *oem-codepage*
        (setq *oem-codepage*
            (gethash (alien-funcall (extern-alien "GetOEMCP" (function UINT)))
                     *codepage-to-external-format*
                     :latin-1)))))

;; http://msdn.microsoft.com/library/en-us/dllproc/base/getconsolecp.asp
(declaim (ftype (function () keyword) console-input-codepage))
(defun console-input-codepage ()
  (or #!+sb-unicode
      (gethash (alien-funcall (extern-alien "GetConsoleCP" (function UINT)))
               *codepage-to-external-format*)
      :latin-1))

;; http://msdn.microsoft.com/library/en-us/dllproc/base/getconsoleoutputcp.asp
(declaim (ftype (function () keyword) console-output-codepage))
(defun console-output-codepage ()
  (or #!+sb-unicode
      (gethash (alien-funcall
                (extern-alien "GetConsoleOutputCP" (function UINT)))
               *codepage-to-external-format*)
      :latin-1))

(define-alien-routine ("LocalFree" local-free) void
  (lptr (* t)))

(defmacro cast-and-free (value &key (type 'system-string)
                                (free-function 'free-alien))
  `(prog1 (cast ,value ,type)
     (,free-function ,value)))

(eval-when (:compile-toplevel :load-toplevel :execute)
(defmacro with-funcname ((name description) &body body)
  `(let
     ((,name (etypecase ,description
               (string ,description)
               (cons (destructuring-bind (s &optional c) ,description
                       (format nil "~A~A" s
                               (if c #!-sb-unicode "A" #!+sb-unicode "W" "")))))))
     ,@body)))

(defmacro make-system-buffer (x)
 `(make-alien char #!+sb-unicode (ash ,x 1) #!-sb-unicode ,x))

(defmacro with-handle ((var initform
                            &key (close-operator 'close-handle))
                            &body body)
  `(without-interrupts
       (block nil
         (let ((,var ,initform))
           (unwind-protect
                (with-local-interrupts
                    ,@body)
             (,close-operator ,var))))))

(define-alien-type pathname-buffer
    (array char #.(ash (1+ max_path) #!+sb-unicode 1 #!-sb-unicode 0)))

(define-alien-type long-pathname-buffer
    #!+sb-unicode (array char 65536)
    #!-sb-unicode pathname-buffer)

(defmacro decode-system-string (alien)
  `(cast (cast ,alien (* char)) system-string))

;;; FIXME: The various FOO-SYSCALL-BAR macros, and perhaps some other
;;; macros in this file, are only used in this file, and could be
;;; implemented using SB!XC:DEFMACRO wrapped in EVAL-WHEN.

(defmacro syscall ((name ret-type &rest arg-types) success-form &rest args)
  (with-funcname (sname name)
    `(locally
       (declare (optimize (sb!c::float-accuracy 0)))
       (let ((result (alien-funcall
                       (extern-alien ,sname
                                     (function ,ret-type ,@arg-types))
                       ,@args)))
         (declare (ignorable result))
         ,success-form))))

;;; This is like SYSCALL, but if it fails, signal an error instead of
;;; returning error codes. Should only be used for syscalls that will
;;; never really get an error.
(defmacro syscall* ((name &rest arg-types) success-form &rest args)
  (with-funcname (sname name)
    `(locally
       (declare (optimize (sb!c::float-accuracy 0)))
       (let ((result (alien-funcall
                       (extern-alien ,sname (function bool ,@arg-types))
                       ,@args)))
         (when (zerop result)
           (win32-error ,sname))
         ,success-form))))

(defmacro with-sysfun ((func name ret-type &rest arg-types) &body body)
  (with-funcname (sname name)
    `(with-alien ((,func (function ,ret-type ,@arg-types)
                         :extern ,sname))
       ,@body)))

(defmacro void-syscall* ((name &rest arg-types) &rest args)
  `(syscall* (,name ,@arg-types) (values t 0) ,@args))

(defun format-system-message (err)
  "http://msdn.microsoft.com/library/default.asp?url=/library/en-us/debug/base/retrieving_the_last_error_code.asp"
  (let ((message
         (with-alien ((amsg (* char)))
           (syscall (("FormatMessage" t)
                     dword dword dword dword dword (* (* char)) dword dword)
                    (cast-and-free amsg :free-function local-free)
                    (logior format-message-allocate-buffer
                            format-message-from-system
                            format-message-max-width-mask
                            format-message-ignore-inserts)
                    0 err 0 (addr amsg) 0 0))))
    (and message (string-right-trim '(#\Space) message))))

(defmacro win32-error (func-name &optional err)
  `(let ((err-code ,(or err `(get-last-error))))
     (declare (type (unsigned-byte 32) err-code))
     (error "~%Win32 Error [~A] - ~A~%~A"
            ,func-name
            err-code
            (format-system-message err-code))))

(defun get-folder-namestring (csidl)
  "http://msdn.microsoft.com/library/en-us/shellcc/platform/shell/reference/functions/shgetfolderpath.asp"
  (with-alien ((apath pathname-buffer))
    (syscall (("SHGetFolderPath" t) int handle int handle dword (* char))
             (concatenate 'string (decode-system-string apath) "\\")
             0 csidl 0 0 (cast apath (* char)))))

(defun get-folder-pathname (csidl)
  (parse-native-namestring (get-folder-namestring csidl)))

(defun sb!unix:posix-getcwd ()
  (with-alien ((apath pathname-buffer))
    (with-sysfun (afunc ("GetCurrentDirectory" t) dword dword (* char))
      (let ((ret (alien-funcall afunc (1+ max_path) (cast apath (* char)))))
        (when (zerop ret)
          (win32-error "GetCurrentDirectory"))
        (if (> ret (1+ max_path))
            (with-alien ((apath (* char) (make-system-buffer ret)))
              (alien-funcall afunc ret apath)
              (cast-and-free apath))
            (decode-system-string apath))))))

(defun sb!unix:unix-mkdir (name mode)
  (declare (type sb!unix:unix-pathname name)
           (type sb!unix:unix-file-mode mode)
           (ignore mode))
  (syscall (("CreateDirectory" t) lispbool system-string (* t))
           (values result (if result 0 (get-last-error)))
           name nil))

(defun sb!unix:unix-rename (name1 name2)
  (declare (type sb!unix:unix-pathname name1 name2))
  (syscall (("MoveFile" t) lispbool system-string system-string)
           (values result (if result 0 (get-last-error)))
           name1 name2))

(defun sb!unix::posix-getenv (name)
  (declare (type simple-string name))
  (with-alien ((aenv (* char) (make-system-buffer default-environment-length)))
    (with-sysfun (afunc ("GetEnvironmentVariable" t)
                        dword system-string (* char) dword)
      (let ((ret (alien-funcall afunc name aenv default-environment-length)))
        (when (> ret default-environment-length)
          (free-alien aenv)
          (setf aenv (make-system-buffer ret))
          (alien-funcall afunc name aenv ret))
        (if (> ret 0)
            (cast-and-free aenv)
            (free-alien aenv))))))

;; GET-CURRENT-PROCESS
;; The GetCurrentProcess function retrieves a pseudo handle for the current
;; process.
;;
;; http://msdn.microsoft.com/library/en-us/dllproc/base/getcurrentprocess.asp
(declaim (inline get-current-process))
(define-alien-routine ("GetCurrentProcess" get-current-process) handle)

;;;; Process time information

(defconstant 100ns-per-internal-time-unit
  (/ 10000000 sb!xc:internal-time-units-per-second))

;; FILETIME
;; The FILETIME structure is a 64-bit value representing the number of
;; 100-nanosecond intervals since January 1, 1601 (UTC).
;;
;; http://msdn.microsoft.com/library/en-us/sysinfo/base/filetime_str.asp?
(define-alien-type FILETIME (sb!alien:unsigned 64))

;; FILETIME definition above is almost correct (on little-endian systems),
;; except for the wrong alignment if used in another structure: the real
;; definition is a struct of two dwords.
;; Let's define FILETIME-MEMBER for that purpose; it will be useful with
;; GetFileAttributesEx and FindFirstFileExW.

(define-alien-type FILETIME-MEMBER
    (struct nil (low dword) (high dword)))

(defmacro with-process-times ((creation-time exit-time kernel-time user-time)
                              &body forms)
  `(with-alien ((,creation-time filetime)
                (,exit-time filetime)
                (,kernel-time filetime)
                (,user-time filetime))
     (syscall* (("GetProcessTimes") handle (* filetime) (* filetime)
                (* filetime) (* filetime))
               (progn ,@forms)
               (get-current-process)
               (addr ,creation-time)
               (addr ,exit-time)
               (addr ,kernel-time)
               (addr ,user-time))))

(declaim (inline system-internal-real-time))

(let ((epoch 0))
  (declare (unsigned-byte epoch))
  ;; FIXME: For optimization ideas see the unix implementation.
  (defun reinit-internal-real-time ()
    (setf epoch 0
          epoch (get-internal-real-time)))
  (defun get-internal-real-time ()
    (- (with-alien ((system-time filetime))
         (syscall (("GetSystemTimeAsFileTime") void (* filetime))
                  (values (floor system-time 100ns-per-internal-time-unit))
                  (addr system-time)))
       epoch)))

(defun system-internal-run-time ()
  (with-process-times (creation-time exit-time kernel-time user-time)
    (values (floor (+ user-time kernel-time) 100ns-per-internal-time-unit))))

(define-alien-type hword (unsigned 16))

(define-alien-type systemtime
    (struct systemtime
            (year hword)
            (month hword)
            (weekday hword)
            (day hword)
            (hour hword)
            (minute hword)
            (second hword)
            (millisecond hword)))

;; Obtained with, but the XC can't deal with that -- but
;; it's not like the value is ever going to change...
;; (with-alien ((filetime filetime)
;;              (epoch systemtime))
;;   (setf (slot epoch 'year) 1970
;;         (slot epoch 'month) 1
;;         (slot epoch 'day) 1
;;         (slot epoch 'hour) 0
;;         (slot epoch 'minute) 0
;;         (slot epoch 'second) 0
;;         (slot epoch 'millisecond) 0)
;;   (syscall (("SystemTimeToFileTime" 8) void
;;             (* systemtime) (* filetime))
;;            filetime
;;            (addr epoch)
;;            (addr filetime)))
(defconstant +unix-epoch-filetime+ 116444736000000000)
(defconstant +filetime-unit+ (* 100ns-per-internal-time-unit
                                internal-time-units-per-second))
(defconstant +common-lisp-epoch-filetime-seconds+ 9435484800)

#!-sb-fluid
(declaim (inline get-time-of-day))
(defun get-time-of-day ()
  "Return the number of seconds and microseconds since the beginning of the
UNIX epoch: January 1st 1970."
  (with-alien ((system-time filetime))
    (syscall (("GetSystemTimeAsFileTime") void (* filetime))
             (multiple-value-bind (sec 100ns)
                 (floor (- system-time +unix-epoch-filetime+)
                        (* 100ns-per-internal-time-unit
                           internal-time-units-per-second))
               (values sec (floor 100ns 10)))
             (addr system-time))))

;; Data for FindFirstFileExW and GetFileAttributesEx
(define-alien-type find-data
    (struct nil
            (attributes dword)
            (ctime filetime-member)
            (atime filetime-member)
            (mtime filetime-member)
            (size-low dword)
            (size-high dword)
            (reserved0 dword)
            (reserved1 dword)
            (long-name (array tchar #.max_path))
            (short-name (array tchar 14))))

(define-alien-type file-attributes
    (struct nil
            (attributes dword)
            (ctime filetime-member)
            (atime filetime-member)
            (mtime filetime-member)
            (size-low dword)
            (size-high dword)))

(define-alien-routine ("FindClose" find-close) lispbool
  (handle handle))

(defun attribute-file-kind (dword)
  (if (logtest file-attribute-directory dword)
      :directory :file))

(defun native-file-write-date (native-namestring)
  "Return file write date, represented as CL universal time."
  (with-alien ((file-attributes file-attributes))
    (syscall (("GetFileAttributesEx" t) lispbool
              system-string int file-attributes)
             (and result
                  (- (floor (deref (cast (slot file-attributes 'mtime)
                                         (* filetime)))
                            +filetime-unit+)
                     +common-lisp-epoch-filetime-seconds+))
             native-namestring 0 file-attributes)))

(defun native-probe-file-name (native-namestring)
  "Return truename \(using GetLongPathName\) as primary value,
File kind as secondary.

Unless kind is false, null truename shouldn't be interpreted as error or file
absense."
  (with-alien ((file-attributes file-attributes)
               (buffer long-pathname-buffer))
    (syscall (("GetFileAttributesEx" t) lispbool
              system-string int file-attributes)
             (values
              (syscall (("GetLongPathName" t) dword
                        system-string long-pathname-buffer dword)
                       (and (plusp result) (decode-system-string buffer))
                       native-namestring buffer 32768)
              (and result
                   (attribute-file-kind
                    (slot file-attributes 'attributes))))
             native-namestring 0 file-attributes)))

(defun native-delete-file (native-namestring)
  (syscall (("DeleteFile" t) lispbool system-string)
           result native-namestring))

(defun native-delete-directory (native-namestring)
  (syscall (("RemoveDirectory" t) lispbool system-string)
           result native-namestring))

(defun native-call-with-directory-iterator (function namestring errorp)
  (declare (type (or null string) namestring)
           (function function))
  (when namestring
    (with-alien ((find-data find-data))
      (with-handle (handle (syscall (("FindFirstFile" t) handle
                                     system-string find-data)
                                    (if (eql result invalid-handle)
                                        (if errorp
                                            (win32-error "FindFirstFile")
                                            (return))
                                        result)
                                    (concatenate 'string
                                                 namestring "*.*")
                                    find-data)
                    :close-operator find-close)
        (let ((more t))
          (dx-flet ((one-iter ()
                      (tagbody
                       :next
                         (when more
                           (let ((name (decode-system-string
                                        (slot find-data 'long-name)))
                                 (attributes (slot find-data 'attributes)))
                             (setf more
                                   (syscall (("FindNextFile" t) lispbool
                                             handle find-data) result
                                             handle find-data))
                             (cond ((equal name ".") (go :next))
                                   ((equal name "..") (go :next))
                                   (t
                                    (return-from one-iter
                                      (values name
                                              (attribute-file-kind
                                               attributes))))))))))
            (funcall function #'one-iter)))))))

;; SETENV
;; The SetEnvironmentVariable function sets the contents of the specified
;; environment variable for the current process.
;;
;; http://msdn.microsoft.com/library/en-us/dllproc/base/setenvironmentvariable.asp
(defun setenv (name value)
  (declare (type (or null simple-string) value))
  (if value
      (void-syscall* (("SetEnvironmentVariable" t) system-string system-string)
                     name value)
      (void-syscall* (("SetEnvironmentVariable" t) system-string int-ptr)
                     name 0)))

;; Let SETENV be an accessor for POSIX-GETENV.
;;
;; DFL: Merged this function because it seems useful to me.  But
;; shouldn't we then define it on actual POSIX, too?
(defun (setf sb!unix::posix-getenv) (new-value name)
  (if (setenv name new-value)
      new-value
      (posix-getenv name)))

(defmacro c-sizeof (s)
  "translate alien size (in bits) to c-size (in bytes)"
  `(/ (alien-size ,s) 8))

;; OSVERSIONINFO
;; The OSVERSIONINFO data structure contains operating system version
;; information. The information includes major and minor version numbers,
;; a build number, a platform identifier, and descriptive text about
;; the operating system. This structure is used with the GetVersionEx function.
;;
;; http://msdn.microsoft.com/library/en-us/sysinfo/base/osversioninfo_str.asp
(define-alien-type nil
  (struct OSVERSIONINFO
    (dwOSVersionInfoSize dword)
    (dwMajorVersion dword)
    (dwMinorVersion dword)
    (dwBuildNumber dword)
    (dwPlatformId dword)
    (szCSDVersion (array char #!-sb-unicode 128 #!+sb-unicode 256))))

(defun get-version-ex ()
  (with-alien ((info (struct OSVERSIONINFO)))
    (setf (slot info 'dwOSVersionInfoSize) (c-sizeof (struct OSVERSIONINFO)))
    (syscall* (("GetVersionEx" t) (* (struct OSVERSIONINFO)))
              (values (slot info 'dwMajorVersion)
                      (slot info 'dwMinorVersion)
                      (slot info 'dwBuildNumber)
                      (slot info 'dwPlatformId)
                      (cast (slot info 'szCSDVersion) system-string))
              (addr info))))

;; GET-COMPUTER-NAME
;; The GetComputerName function retrieves the NetBIOS name of the local
;; computer. This name is established at system startup, when the system
;; reads it from the registry.
;;
;; http://msdn.microsoft.com/library/en-us/sysinfo/base/getcomputername.asp
(declaim (ftype (function () simple-string) get-computer-name))
(defun get-computer-name ()
  (with-alien ((aname (* char) (make-system-buffer (1+ MAX_COMPUTERNAME_LENGTH)))
               (length dword (1+ MAX_COMPUTERNAME_LENGTH)))
    (with-sysfun (afunc ("GetComputerName" t) bool (* char) (* dword))
      (when (zerop (alien-funcall afunc aname (addr length)))
        (let ((err (get-last-error)))
          (unless (= err ERROR_BUFFER_OVERFLOW)
            (win32-error "GetComputerName" err))
          (free-alien aname)
          (setf aname (make-system-buffer length))
          (alien-funcall afunc aname (addr length))))
      (cast-and-free aname))))

(define-alien-routine ("SetFilePointerEx" set-file-pointer-ex) lispbool
  (handle handle)
  (offset long-long)
  (new-position long-long :out)
  (whence dword))

(defun lseeki64 (handle offset whence)
  (multiple-value-bind (moved to-place)
      (set-file-pointer-ex handle offset whence)
    (if moved
        (values to-place 0)
        (values -1 (get-last-error)))))

;; File mapping support routines
(define-alien-routine (#!+sb-unicode "CreateFileMappingW"
                       #!-sb-unicode "CreateFileMappingA"
                       create-file-mapping)
    handle
  (handle handle)
  (security-attributes (* t))
  (protection dword)
  (maximum-size-high dword)
  (maximum-size-low dword)
  (name system-string))

(define-alien-routine ("MapViewOfFile" map-view-of-file)
    system-area-pointer
  (file-mapping handle)
  (desired-access dword)
  (offset-high dword)
  (offset-low dword)
  (size dword))

(define-alien-routine ("UnmapViewOfFile" unmap-view-of-file) bool
  (address (* t)))

(define-alien-routine ("FlushViewOfFile" flush-view-of-file) bool
  (address (* t))
  (length dword))

;; Constants for CreateFile `disposition'.
(defconstant file-create-new 1)
(defconstant file-create-always 2)
(defconstant file-open-existing 3)
(defconstant file-open-always 4)
(defconstant file-truncate-existing 5)

;; access rights
(defconstant access-generic-read #x80000000)
(defconstant access-generic-write #x40000000)
(defconstant access-generic-execute #x20000000)
(defconstant access-generic-all #x10000000)
(defconstant access-file-append-data #x4)
(defconstant access-delete #x00010000)

;; share modes
(defconstant file-share-delete #x04)
(defconstant file-share-read #x01)
(defconstant file-share-write #x02)

;; CreateFile (the real file-opening workhorse).
(define-alien-routine (#!+sb-unicode "CreateFileW"
                       #!-sb-unicode "CreateFileA"
                       create-file)
    handle
  (name (c-string #!+sb-unicode #!+sb-unicode :external-format :ucs-2))
  (desired-access dword)
  (share-mode dword)
  (security-attributes (* t))
  (creation-disposition dword)
  (flags-and-attributes dword)
  (template-file handle))

;; GetFileSizeEx doesn't work with block devices :[
(define-alien-routine ("GetFileSizeEx" get-file-size-ex)
    bool
  (handle handle) (file-size (signed 64) :in-out))

;; GetFileAttribute is like a tiny subset of fstat(),
;; enough to distinguish directories from anything else.
(define-alien-routine (#!+sb-unicode "GetFileAttributesW"
                       #!-sb-unicode "GetFileAttributesA"
                       get-file-attributes)
    dword
  (name (c-string #!+sb-unicode #!+sb-unicode :external-format :ucs-2)))

(define-alien-routine ("CloseHandle" close-handle) bool
  (handle handle))

(define-alien-routine ("_open_osfhandle" real-open-osfhandle)
    int
  (handle handle)
  (flags int))

;; Intended to be an imitation of sb!unix:unix-open based on
;; CreateFile, as complete as possibly.
;; FILE_FLAG_OVERLAPPED is a must for decent I/O.

(defun unixlike-open (path flags mode &optional revertable)
  (declare (type sb!unix:unix-pathname path)
           (type fixnum flags)
           (type sb!unix:unix-file-mode mode)
           (ignorable mode))
  (let* ((disposition-flags
          (logior
           (if (zerop (logand sb!unix:o_creat flags)) 0 #b100)
           (if (zerop (logand sb!unix:o_excl flags)) 0 #b010)
           (if (zerop (logand sb!unix:o_trunc flags)) 0 #b001)))
         (create-disposition
          ;; there are 8 combinations of creat|excl|trunc, some of
          ;; them are equivalent. Case stmt below maps them to 5
          ;; dispositions (see CreateFile manual).
          (case disposition-flags
            ((#b110 #b111) file-create-new)
            ((#b001 #b011) file-truncate-existing)
            ((#b000 #b010) file-open-existing)
            (#b100 file-open-always)
            (#b101 file-create-always))))
    (let ((handle
           (create-file path
                        (logior
                         (if revertable #x10000 0)
                         (if (plusp (logand sb!unix:o_append flags))
                             access-file-append-data
                             0)
                         (ecase (logand 3 flags)
                           (0 FILE_GENERIC_READ)
                           (1 FILE_GENERIC_WRITE)
                           ((2 3) (logior FILE_GENERIC_READ
                                          FILE_GENERIC_WRITE))))
                        (logior FILE_SHARE_READ
                                FILE_SHARE_WRITE)
                        nil
                        create-disposition
                        (logior
                         file-attribute-normal
                         file-flag-overlapped
                         file-flag-sequential-scan)
                        0)))
      (if (eql handle invalid-handle)
          (values nil
                  (let ((error-code (get-last-error)))
                    (case error-code
                      (#.error_file_not_found
                       sb!unix:enoent)
                      ((#.error_already_exists #.error_file_exists)
                       sb!unix:eexist)
                      (otherwise error-code))))
          (progn
            ;; FIXME: seeking to the end is not enough for real APPEND
            ;; semantics, but it's better than nothing.
            ;;   -- AK
            ;;
            ;; On the other hand, the CL spec implies the "better than
            ;; nothing" seek-once semantics implemented here, and our
            ;; POSIX backend is incorrect in implementing :APPEND as
            ;; O_APPEND.  Other CL implementations get this right across
            ;; platforms.
            ;;
            ;; Of course, it would be nice if we had :IF-EXISTS
            ;; :ATOMICALLY-APPEND separately as an extension, and in
            ;; that case, we will have to worry about supporting it
            ;; here after all.
            ;;
            ;; I've tested this only very briefly (on XP and Windows 7),
            ;; but my impression is that WriteFile (without documenting
            ;; it?) is like ZwWriteFile, i.e. if we pass in -1 as the
            ;; offset in our overlapped structure, WriteFile seeks to the
            ;; end for us.  Should we depend on that?  How do we communicate
            ;; our desire to do so to the runtime?
            ;;   -- DFL
            ;;
            (set-file-pointer-ex handle 0 (if (plusp (logand sb!unix::o_append flags)) 2 0))
            (values handle 0))))))

(define-alien-routine ("closesocket" close-socket) int (handle handle))
(define-alien-routine ("shutdown" shutdown-socket) int (handle handle)
  (how int))

(define-alien-routine ("DuplicateHandle" duplicate-handle) lispbool
  (from-process handle)
  (from-handle handle)
  (to-process handle)
  (to-handle handle :out)
  (access dword)
  (inheritp lispbool)
  (options dword))

(defconstant +handle-flag-inherit+ 1)
(defconstant +handle-flag-protect-from-close+ 2)

(define-alien-routine ("SetHandleInformation" set-handle-information) lispbool
  (handle handle)
  (mask dword)
  (flags dword))

(define-alien-routine ("GetHandleInformation" get-handle-information) lispbool
  (handle handle)
  (flags dword :out))

(define-alien-routine getsockopt int
  (handle handle)
  (level int)
  (opname int)
  (dataword int-ptr :in-out)
  (socklen int :in-out))

(defconstant sol_socket #xFFFF)
(defconstant so_type #x1008)

(defun socket-handle-p (handle)
  (zerop (getsockopt handle sol_socket so_type 0 (alien-size int :bytes))))

(defconstant ebadf 9)

;;; For sockets, CloseHandle first and closesocket() afterwards is
;;; legal: winsock tracks its handles separately (that's why we have
;;; the problem with simple _close in the first place).
;;;
;;; ...Seems to be the problem on some OSes, though. We could
;;; duplicate a handle and attempt close-socket on a duplicated one,
;;; but it also have some problems...

(defun unixlike-close (fd)
  (if (or (zerop (close-socket fd))
          (close-handle fd))
      t (values nil ebadf)))

(defconstant +std-input-handle+ -10)
(defconstant +std-output-handle+ -11)
(defconstant +std-error-handle+ -12)

(defun get-std-handle-or-null (identity)
  (let ((handle (alien-funcall
                 (extern-alien "GetStdHandle" (function handle dword))
                 (logand (1- (ash 1 (alien-size dword))) identity))))
    (and (/= handle invalid-handle)
         (not (zerop handle))
         ;;When a gui process is launched in windows (subsystem WINDOWS)
         ;;it inherits the parent process' handles, which may very well be
         ;;invalid unless properly orchestrated by the parent process.
         ;;Win32 io will fail on these handles and there is no meaningful
         ;;way to make use of them.
         ;;So we can call GetFileType to verify the validity of the std handle
         ;;which returns FILE_TYPE_UNKNOWN if the handle is invalid
         ;;Technically it also returns FILE_TYPE_UNKNOWN if the function fails
         ;;but I can't think of a reason we'd care, nor what to do about it
         (not (zerop (get-file-type handle)))
         handle)))

(defun get-std-handles ()
  (values (get-std-handle-or-null +std-input-handle+)
          (get-std-handle-or-null +std-output-handle+)
          (get-std-handle-or-null +std-error-handle+)))

(defconstant +duplicate-same-access+ 2)

(defun duplicate-and-unwrap-fd (fd &key inheritp)
  (let ((me (get-current-process)))
    (multiple-value-bind (duplicated handle)
        (duplicate-handle me (real-get-osfhandle fd)
                          me 0 inheritp +duplicate-same-access+)
      (if duplicated
          (prog1 handle (real-crt-close fd))
          (win32-error 'duplicate-and-unwrap-fd)))))

(define-alien-routine ("CreatePipe" create-pipe) lispbool
  (read-pipe handle :out)
  (write-pipe handle :out)
  (security-attributes (* t))
  (buffer-size dword))

(defun windows-pipe ()
  (multiple-value-bind (created read-handle write-handle)
      (create-pipe nil 256)
    (if created (values read-handle write-handle)
        (win32-error 'create-pipe))))

(defun windows-isatty (handle)
  (if (= file-type-char (get-file-type handle))
      1 0))

(defun inheritable-handle-p (handle)
  (multiple-value-bind (got flags)
      (get-handle-information handle)
    (if got (plusp (logand flags +handle-flag-inherit+))
        (win32-error 'inheritable-handle-p))))

(defun (setf inheritable-handle-p) (allow handle)
  (if (set-handle-information handle
                              +handle-flag-inherit+
                              (if allow +handle-flag-inherit+ 0))
      allow
      (win32-error '(setf inheritable-handle-p))))

(defun sb!unix:unix-dup (fd)
  (let ((me (get-current-process)))
    (multiple-value-bind (duplicated handle)
        (duplicate-handle me fd me 0 t +duplicate-same-access+)
      (if duplicated
          (values handle 0)
          (values nil (get-last-error))))))

(defun call-with-crt-fd (thunk handle &optional (flags 0))
  (multiple-value-bind (duplicate errno)
      (sb!unix:unix-dup handle)
    (if duplicate
        (let ((fd (real-open-osfhandle duplicate flags)))
          (unwind-protect (funcall thunk fd)
            (real-crt-close fd)))
        (values nil errno))))

;;; random seeding

(define-alien-routine ("CryptGenRandom" %crypt-gen-random) lispbool
  (handle handle)
  (length dword)
  (buffer (* t)))

(define-alien-routine (#!-sb-unicode "CryptAcquireContextA"
                       #!+sb-unicode "CryptAcquireContextW"
                       %crypt-acquire-context) lispbool
  (handle handle :out)
  (container system-string)
  (provider system-string)
  (provider-type dword)
  (flags dword))

(define-alien-routine ("CryptReleaseContext" %crypt-release-context) lispbool
  (handle handle)
  (flags dword))

(defun crypt-gen-random (length)
  (multiple-value-bind (ok context)
      (%crypt-acquire-context nil nil prov-rsa-full
                              (logior crypt-verifycontext crypt-silent))
    (unless ok
      (return-from crypt-gen-random (values nil (get-last-error))))
    (unwind-protect
         (let ((data (make-array length :element-type '(unsigned-byte 8))))
           (with-pinned-objects (data)
             (if (%crypt-gen-random context length (vector-sap data))
                 data
                 (values nil (get-last-error)))))
      (unless (%crypt-release-context context 0)
        (win32-error '%crypt-release-context)))))
