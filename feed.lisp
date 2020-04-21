#|
 This file is a part of Courier
 (c) 2019 Shirakumo http://tymoon.eu (shinmera@tymoon.eu)
 Author: Nicolas Hafner <shinmera@tymoon.eu>
|#

(in-package #:courier)

(defun ensure-feed (feed-ish)
  (or
   (etypecase feed-ish
     (dm:data-model feed-ish)
     (T (dm:get-one 'feed (db:query (:= '_id (db:ensure-id feed-ish))))))
   (error 'request-not-found :message "No such feed.")))

(defun list-feeds (campaign &key amount (skip 0))
  (dm:get 'feed (db:query (:= 'campaign (ensure-id campaign)))
          :sort '((title :asc)) :skip skip :amount amount))

(defun make-feed (campaign url &key title (frequency 10) template (send-new T) backfill (save T))
  (let* ((data (when save (fetch-feed url)))
         (title (or title (when data (feeder:title data)) ""))
         (template (or template (alexandria:read-file-into-string (@template "email/default-feed.ctml"))))
         (feed (dm:hull 'feed))
         (frequency (max 1 frequency)))
    (setf-dm-fields feed campaign url title frequency template send-new)
    (setf (dm:field feed "last-update") (get-universal-time))
    (when save
      (db:with-transaction ()
        (dm:insert feed)
        (unless backfill
          (dolist (entry (feeder:content data))
            (db:insert 'feed-entry `(("feed" . ,(dm:id feed))
                                     ("guid" . ,(feed-guid entry))))))))
    (notify-task 'update-all-feeds)
    feed))

(defun edit-feed (feed &key url title frequency template (send-new NIL send-new-p))
  (db:with-transaction ()
    (let ((feed (ensure-feed feed))
          (frequency (when frequency (max 1 frequency))))
      ;; Ensure the URL is valid.
      (when url (fetch-feed url))
      (setf-dm-fields feed url title frequency template)
      (when send-new-p
        (setf (dm:field feed "send-new") send-new))
      (dm:save feed)))
  (notify-task 'update-all-feeds)
  feed)

(defun delete-feed (feed)
  (db:with-transaction ()
    (let ((feed (ensure-feed feed)))
      (db:remove 'feed-entry (db:query (:= 'feed (dm:id feed))))
      (dm:delete feed))))

(defun fetch-feed (url)
  (flet ((fail (message)
           (error 'api-argument-invalid :argument 'url :message message)))
    (handler-case
        (let* ((drakma:*text-content-types* '(("application" . "atom+xml")
                                              ("application" . "rss+xml")
                                              ("application" . "xml")
                                              ("text" . "xml"))))
          (multiple-value-bind (body status) (drakma:http-request url)
            (when (/= status 200)
              (fail "The server replied with an error. Are you sure the URL is correct?"))
            (unless (typep body 'string)
              (fail "The given URL does not seem to point to a feed in Atom or RSS 2.0 format."))
            (first (feeder:parse-feed body T))))
      (usocket:ns-error ()
        (fail "Failed to resolve the target hostname. Are you sure the URL is correct?"))
      (usocket:socket-error ()
        (fail "Failed to connect to the remote server. Are you sure the URL is correct?"))
      (drakma:drakma-error ()
        (fail "Failed to fetch the feed. Are you sure the URL is correct?"))
      (feeder:unknown-format ()
        (fail "The given URL does not seem to point to a feed in Atom or RSS 2.0 format.")))))

(defun feed-guid (entry)
  (typecase (feeder:id entry)
    (feeder:link (feeder:url (feeder:id entry)))
    (string (feeder:id entry))
    (T (princ-to-string (feeder:id entry)))))

(defun feed-variables (feed entry)
  ;; FIXME: how do we splice the HTML content?
  (list :id (feed-guid entry)
        :authors (or (feeder:authors entry) (feeder:authors feed))
        :contributors (or (feeder:contributors entry) (feeder:contributors feed))
        :categories (or (feeder:categories entry) (feeder:categories feed))
        :language (or (feeder:language entry) (feeder:language feed))
        :published-on (feeder:published-on entry)
        :link (when (feeder:link entry) (feeder:url (feeder:link entry)))
        :title (feeder:title entry)
        :summary (feeder:summary entry)
        :content (feeder:content entry)
        :comment-section (feeder:comment-section entry)
        :source (when (feeder:source entry) (feeder:url (feeder:source entry)))
        :generator (feeder:generator feed)
        :logo (feeder:logo feed)
        :webmaster (feeder:webmaster feed)
        :feed-link (when (feeder:link feed) (feeder:url (feeder:link feed)))))

(defun process-feed-entry (feed data entry)
  (db:with-transaction ()
    (let* ((content (compile-mail-body (dm:field feed "template") :ctml :html
                                       :vars (feed-variables data entry)))
           (mail (make-mail (dm:field feed "campaign")
                            :title (feeder:title entry)
                            ;; FIXME: allow customising this
                            :subject (feeder:title entry)
                            :body content
                            :type :ctml)))
      (db:insert 'feed-entry `(("feed" . ,(dm:id feed))
                               ("mail" . ,(dm:id mail))
                               ("guid" . ,(feed-guid entry))))
      (when (dm:field feed "send-new")
        (enqueue-mail mail)))))

(defun update-feed (feed)
  (l:debug :courier.feed "Updating ~a" feed)
  (let* ((feed (ensure-feed feed))
         (data (fetch-feed (dm:field feed "url"))))
    (loop for entry in (feeder:content data)
          for guid = (feed-guid entry)
          do (unless (< 0 (db:count 'feed-entry (db:query (:and (:= 'feed (dm:id feed))
                                                                (:= 'guid guid)))))
               (l:info :courier.feed "Found new entry with guid ~a in ~a" guid feed)
               (process-feed-entry feed data entry)))
    (setf (dm:field feed "last-update") (get-universal-time))))

(defun maybe-update-feed (feed)
  (let ((feed (ensure-feed feed)))
    (when (< (+ (dm:field feed "last-update")
                (* 60 (dm:field feed "frequency")))
             (get-universal-time))
      (update-feed feed))))

(defun update-all-feeds ()
  (let ((feeds (dm:get 'feed (db:query :all) :sort '((last-update :desc)))))
    (loop for feed in feeds
          do (maybe-update-feed feed)
          minimize (+ (dm:field feed "last-update")
                      (* 60 (dm:field feed "frequency"))))))

(define-task update-all-feeds ()
  (setf (due-time task) (update-all-feeds)))
