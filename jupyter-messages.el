(require 'hmac-def)
(require 'cl-lib)
(require 'json)

(defconst jupyter-protocol-version "5.3"
  "The jupyter protocol version that is implemented.")

(defconst jupyter-message-delimiter "<IDS|MSG>"
  "The message delimiter required in the jupyter messaging
protocol.")

(defconst jupyter--false :json-false
  "The symbol used to disambiguate nil from a true boolean
false.")

(defconst jupyter--received-message-types
  (list 'execute-result "execute_result"
        'execute-reply "execute_reply"
        'inspect-reply "inspect_reply"
        'complete-reply "complete_reply"
        'history-reply "history_reply"
        'is-complete-reply "is_complete_reply"
        'comm-info-reply "comm_info_reply"
        'kernel-info-reply "kernel_info_reply"
        'shutdown-reply "shutdown_reply"
        'interrupt-reply "interrupt_reply"
        'stream "stream"
        'display-data "display_data"
        'update-display-data "update_display_data"
        'execute-input "execute_input"
        'error "error"
        'status "status"
        'clear-output "clear_output"
        'input-reply "input_reply")
  "A plist mapping symbols to received message types.
This is used to give some protection against invalid message
types in `jupyter-add-receive-callback'. If the MSG-TYPE argument
of `jupyter-add-receive-callback' does not match one of the keys
in this plist, an error is thrown.")

;;; Session object

(cl-defstruct (jupyter-session
               (:constructor nil)
               (:constructor
                jupyter-session
                (&key (key nil) &aux (id (jupyter--new-uuid)))))
  (id nil :read-only t)
  (key nil :read-only t))

;;; Signing messages

;; https://tools.ietf.org/html/rfc4868
(defun sha256 (object)
  (secure-hash 'sha256 object nil nil t))
(define-hmac-function hmac-sha256 sha256 64 32)

(defun jupyter--sign-message (session parts)
  (if (> (length (jupyter-session-key session)) 0)
      (cl-loop
       for b across (hmac-sha256 (mapconcat #'identity parts "")
                                 (jupyter-session-key session))
       concat (format "%02x" b))
    ""))

(defun jupyter--new-uuid ()
  "Make a version 4 UUID."
  (format "%04x%04x-%04x-%04x-%04x-%06x%06x"
          (cl-random 65536)
          (cl-random 65536)
          (cl-random 65536)
          ;; https://tools.ietf.org/html/rfc4122
          (let ((r (cl-random 65536)))
            (if (= (byteorder) ?l)
                ;; ?l = little-endian
                (logior (logand r 4095) 16384)
              ;; big-endian
              (logior (logand r 65295) 64)))
          (let ((r (cl-random 65536)))
            (if (= (byteorder) ?l)
                (logior (logand r 49151) 32768)
              (logior (logand r 65471) 128)))
          (cl-random 16777216)
          (cl-random 16777216)))

(defun jupyter--split-identities (parts)
  "Extract the identities from a list of message PARTS."
  (let ((idents nil))
    (if (catch 'found-delim
          (while (car parts)
            (when (string= (car parts) jupyter-message-delimiter)
              (setq parts (cdr parts)
                    idents (nreverse idents))
              (throw 'found-delim t))
            (setq idents (cons (car parts) idents)
                  parts (cdr parts))))
        (cons idents parts)
      (error "Message delimiter not in message list"))))

(defun jupyter--message-header (session msg-type)
  (list
   :msg_id (jupyter--new-uuid)
   :msg_type msg-type
   :version jupyter-protocol-version
   :username user-login-name
   :session (jupyter-session-id session)
   :date (format-time-string "%FT%T%z" (current-time))))

;;; Encode/decoding messages

(defun jupyter--encode-object (object)
  ;; Encodes nil or "" to \"{}\"
  (encode-coding-string (json-encode-plist object) 'utf-8))

(defun jupyter--decode-string (str)
  (let ((json-object-type 'plist)
        (json-array-type 'list))
    (json-read-from-string (decode-coding-string str 'utf-8))))

(cl-defun jupyter--encode-message (session
                                   type
                                   &key idents
                                   content
                                   parent-header
                                   metadata
                                   buffers)
  (declare (indent 2))
  (cl-check-type session jupyter-session)
  (cl-check-type metadata json-plist)
  (cl-check-type content json-plist)
  (cl-check-type buffers list)
  (let* ((header (jupyter--message-header session type))
         (msg-id (plist-get header :msg_id))
         (parts (mapcar #'jupyter--encode-object (list header
                                                  parent-header
                                                  metadata
                                                  content))))
    (cons msg-id
          (append
           (when idents (if (stringp idents) (list idents) idents))
           (list jupyter-message-delimiter
                 (jupyter--sign-message session parts))
           parts
           buffers))))

(defun jupyter--decode-message (session parts)
  (when (< (length parts) 5)
    (error "Malformed message. Minimum length of parts is 5."))
  (when (jupyter-session-key session)
    (let ((signature (car parts)))
      (when (seq-empty-p signature)
        (error "Unsigned message."))
      ;; TODO: digest_history
      ;; https://github.com/jupyter/jupyter_client/blob/7a0278af7c1652ac32356d6f00ae29d24d78e61c/jupyter_client/session.py#L915
      (unless (string= (jupyter--sign-message session (seq-subseq parts 1 5))
                       signature)
        (error "Invalid signature: %s" signature))))
  (cl-destructuring-bind
      (header parent-header metadata content &optional buffers)
      (cdr parts)
    (let ((header (jupyter--decode-string header)))
      (list
       :header header
       :msg_id (plist-get header :msg_id)
       :msg_type (plist-get header :msg_type)
       :parent_header (jupyter--decode-string parent-header)
       :metadata (jupyter--decode-string metadata)
       :content (jupyter--decode-string content)
       :buffers buffers))))

;;; stdin messages

(cl-defun jupyter-input-reply (&key value)
  (cl-check-type value string)
  (list :value value))

;;; shell messages

(cl-defun jupyter-execute-request (&key
                                   code
                                   (silent nil)
                                   (store-history t)
                                   (user-expressions nil)
                                   (allow-stdin t)
                                   (stop-on-error nil))
  (cl-check-type code string)
  (cl-check-type user-expressions json-plist)
  (list :code code :silent (if silent t jupyter--false)
        :store_history (if store-history t jupyter--false)
        :user_expressions user-expressions
        :allow_stdin (if allow-stdin t jupyter--false)
        :stop_on_error (if stop-on-error t jupyter--false)))

(cl-defun jupyter-inspect-request (&key code pos detail)
  (setq detail (or detail 0))
  (unless (member detail '(0 1))
    (error "Detail can only be 0 or 1 (%s)" detail))
  (when (markerp pos)
    (setq pos (marker-position pos)))
  (cl-check-type code string)
  (cl-check-type pos integer)
  (list :code code :cursor_pos pos :detail_level detail))

(cl-defun jupyter-complete-request (&key code pos)
  (when (markerp pos)
    (setq pos (marker-position pos)))
  (cl-check-type code string)
  (cl-check-type pos integer)
  (list :code code :cursor_pos pos))

(cl-defun jupyter-history-request (&key
                                   output
                                   raw
                                   hist-access-type
                                   session
                                   start
                                   stop
                                   n
                                   pattern
                                   unique)
  (unless (member hist-access-type '("range" "tail" "search"))
    (error "History access type can only be one of (range, tail, search)"))
  (append
   (list :output (if output t jupyter--false) :raw (if raw t jupyter--false)
         :hist_access_type hist-access-type)
   (cond
    ((equal hist-access-type "range")
     (cl-check-type session integer)
     (cl-check-type start integer)
     (cl-check-type stop integer)
     (list :session session :start start :stop stop))
    ((equal hist-access-type "tail")
     (cl-check-type n integer)
     (list :n n))
    ((equal hist-access-type "search")
     (cl-check-type pattern string)
     (cl-check-type n integer)
     (list :pattern pattern :unique (if unique t jupyter--false) :n n)))))

(cl-defun jupyter-is-complete-request (&key code)
  (cl-check-type code string)
  (list :code code))

(cl-defun jupyter-comm-info-request (&key target-name)
  (when target-name
    (cl-check-type target-name string)
    (list :target_name target-name)))

(cl-defun jupyter-shutdown-request (&key restart)
  (list :restart (if restart t jupyter--false)))

;;; Convenience functions

(defun jupyter-message-id (msg)
  (plist-get msg :msg_id))

(defun jupyter-message-parent-id (msg)
  (jupyter-message-id
   (plist-get msg :parent_header)))

(defun jupyter-message-status-idle-p (msg)
  (and (equal (plist-get msg :msg_type) "status")
       (equal (plist-get (plist-get msg :content) :execution_state)
              "idle")))

(defun jupyter-message-type (msg)
  (plist-get msg :msg_type))

(provide 'jupyter-messages)

;; Local Variables:
;; byte-compile-warnings: (not free-vars)
;; End:
