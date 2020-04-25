#|
 This file is a part of Courier
 (c) 2019 Shirakumo http://tymoon.eu (shinmera@tymoon.eu)
 Author: Nicolas Hafner <shinmera@tymoon.eu>
|#

(in-package #:courier)

(defun make-subscriber (campaign name address &key attributes tags (status :unconfirmed) (signup-time (get-universal-time)) (save t))
  (db:with-transaction ()
    (when (< 0 (db:count 'subscriber (db:query (:and (:= 'campaign (dm:id campaign))
                                                     (:= 'address address)))))
      (error 'api-argument-invalid :argument 'address :message "This email address is already subscribed."))
    (dm:with-model subscriber ('subscriber NIL)
      (setf-dm-fields subscriber campaign name address)
      (setf (dm:field subscriber "status") (user-status-id status))
      (setf (dm:field subscriber "signup-time") signup-time)
      (when save
        (dm:insert subscriber)
        (loop for (attribute . value) in attributes
              do (dm:with-model attribute-value ('attribute-value NIL)
                   ;; FIXME: check attributes for validity
                   (setf (dm:field attribute-value "attribute") (ensure-id attribute))
                   (setf (dm:field attribute-value "subscriber") (dm:id subscriber))
                   (setf (dm:field attribute-value "value") value)
                   (dm:insert attribute-value)))
        (loop for tag in tags
              do (tag subscriber tag))
        (when (eql :active status)
          (process-triggers subscriber campaign)))
      subscriber)))

(defun edit-subscriber (subscriber &key name address attributes tags status (save T))
  (db:with-transaction ()
    (let ((subscriber (ensure-subscriber subscriber)))
      (setf-dm-fields subscriber name address)
      (setf (dm:field subscriber "status") (user-status-id status))
      (when save
        (dm:save subscriber)
        (loop for (attribute . value) in attributes
              do (let ((attribute-value (or (dm:get-one 'attribute-value (db:query (:and (:= 'attribute (ensure-id attribute))
                                                                                         (:= 'subscriber (dm:id subscriber)))))
                                            (dm:hull 'attribute-value))))
                   (setf (dm:field attribute-value "attribute") (ensure-id attribute))
                   (setf (dm:field attribute-value "subscriber") (dm:id subscriber))
                   (setf (dm:field attribute-value "value") value)
                   (if (dm:hull-p attribute-value)
                       (dm:insert attribute-value)
                       (dm:save attribute-value))))
        (db:remove 'tag-table (db:query (:= 'subscriber (dm:id subscriber))))
        (loop for tag in tags
              do (tag subscriber tag))
        (when (eql :active status)
          (process-triggers subscriber (ensure-campaign (dm:field subscriber "campaign")))))
      subscriber)))

(defun ensure-subscriber (subscriber-ish)
  (or
   (etypecase subscriber-ish
     (dm:data-model subscriber-ish)
     (T (dm:get-one 'subscriber (db:query (:= '_id (db:ensure-id subscriber-ish))))))
   (error 'request-not-found :message "No such subscriber.")))

(defun delete-subscriber (subscriber)
  (db:with-transaction ()
    (db:remove 'attribute-value (db:query (:= 'subscriber (dm:id subscriber))))
    (db:remove 'mail-receipt (db:query (:= 'subscriber (dm:id subscriber))))
    (db:remove 'mail-log (db:query (:= 'subscriber (dm:id subscriber))))
    (db:remove 'mail-queue (db:query (:= 'subscriber (dm:id subscriber))))
    (db:remove 'tag-table (db:query (:= 'subscriber (dm:id subscriber))))
    (db:remove 'mail-receipt (db:query (:= 'subscriber (dm:id subscriber))))
    (dm:delete subscriber)))

(defun list-subscribers (thing &key amount (skip 0) query)
  (macrolet ((query (clause)
               `(if query
                    (let ((query (prepare-query query)))
                      (db:query (:and ,clause
                                      (:or (:matches 'name query)
                                           (:matches 'address query)))))
                    (db:query ,clause))))
    (ecase (dm:collection thing)
      (campaign
       (dm:get 'subscriber (query (:= 'campaign (dm:id thing)))
               :sort '((signup-time :DESC)) :amount amount :skip skip))
      (tag
       (dm:get (rdb:join (subscriber _id) (tag-table subscriber)) (query (:= 'tag (dm:id thing)))
               :sort '((signup-time :DESC)) :amount amount :skip skip :hull 'subscriber))
      (link
       (dm:get (rdb:join (subscriber _id) (link-receipt subscriber)) (query (:= 'link (dm:id thing)))
               :sort '((signup-time :DESC)) :amount amount :skip skip :hull 'subscriber)))))

(defun subscriber-attributes (subscriber)
  (loop for attribute in (db:select (rdb:join (attribute _id) (attribute-value attribute))
                                    (db:query (:= 'subscriber (ensure-id subscriber))))
        collect (gethash "title" attribute)
        collect (gethash "value" attribute)))

(defun subscriber-count (thing)
  (ecase (dm:collection thing)
    (campaign (db:count 'subscriber (db:query (:= 'campaign (dm:id thing)))))
    (tag (db:count 'tag-table (db:query (:= 'tag (dm:id thing)))))))

(defun new-subscribers-since (campaign time)
  (dm:get 'subscriber (db:query (:and (:= 'campaign (ensure-id campaign))
                                      (:= 'status (user-status-id :active))
                                      (:<= time 'signup-time)))
          :sort '((address :asc))))

(defun user-status-id (status)
  (ecase status
    (:unconfirmed 0)
    (:active 1)
    (:deactivated 2)
    ((0 1 2) status)))

(defun id-user-status (id)
  (ecase id
    (0 :unconfirmed)
    (1 :active)
    (2 :deactivated)))

(defun prune-unconfirmed-subscribers ()
  (let* ((expiry-time (- (get-universal-time) (* 60 60 24)))
         (matching (dm:get 'subscriber (db:query (:and (:= 'status (user-status-id :unconfirmed))
                                                       (:< 'signup-time expiry-time)))
                           :amount 10)))
    (when matching
      (dolist (subscriber matching T)
        (l:info :courier.prune "Pruning unconfirmed subscriber ~a" (dm:field subscriber "address"))
        (delete-subscriber subscriber)))))

(define-task prune-unconfirmed-subscribers ()
  (unless (prune-unconfirmed-subscribers)
    ;; TODO: be smarter about this and schedule for the nearest matching instead.
    (reschedule-in (* 12 60 60) task)))