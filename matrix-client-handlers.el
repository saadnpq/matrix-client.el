;;; matrix-client-handlers.el --- Event handlers for Matrix.org RPC

;; Copyright (C) 2015 Ryan Rix
;; Author: Ryan Rix <ryan@whatthefuck.computer>
;; Maintainer: Ryan Rix <ryan@whatthefuck.computer>
;; Created: 21 June 2015
;; Keywords: web
;; Homepage: http://doc.rix.si/matrix.html
;; Package-Version: 0.1.0
;; Package-Requires: ((json))

;; This file is not part of GNU Emacs.

;; matrix-client-handlers.el is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by the Free
;; Software Foundation, either version 3 of the License, or (at your option) any
;; later version.
;;
;; matrix-client-handlers.el is distributed in the hope that it will be useful, but
;; WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
;; FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General Public License for
;; more details.
;;
;; You should have received a copy of the GNU General Public License along with
;; this file.  If not, see <http://www.gnu.org/licenses/>.

;;; Commentary:

;; This file holds the standard matrix-client handlers and input filters. See the docstring of
;; [`matrix-client-handlers-init'] and [`defmatrix-client-handler'] for information about these.

;;; Code:

(defun matrix-client-handlers-init ()
  "Set up all the matrix-client event type handlers.


Each matrix-client-event-handler is an alist of matrix message type and
the function that handles them.  Currently only a single handler
for each event is supported.  The handler takes a single argument,
DATA, which is a `json-read' object from the Event stream.  See
the Matrix spec for more information about its format."
  (setq matrix-client-event-handlers nil)
  (setq matrix-client-input-filters nil)
  (add-to-list 'window-configuration-change-hook 'matrix-client-window-change-hook)
  (add-to-list 'matrix-client-event-handlers '("m.room.message" . matrix-client-handler-m.room.message))
  (add-to-list 'matrix-client-event-handlers '("m.lightrix.pattern" . matrix-client-handler-m.lightrix.pattern))
  (add-to-list 'matrix-client-event-handlers '("m.room.topic" . matrix-client-handler-m.room.topic))
  (add-to-list 'matrix-client-event-handlers '("m.room.name" . matrix-client-handler-m.room.name))
  (add-to-list 'matrix-client-event-handlers '("m.room.member" . matrix-client-handler-m.room.member))
  (add-to-list 'matrix-client-event-handlers '("m.room.aliases" . matrix-client-handler-m.room.aliases))
  (add-to-list 'matrix-client-event-handlers '("m.presence" . matrix-client-handler-m.presence))
  (add-to-list 'matrix-client-event-handlers '("m.typing" . matrix-client-handler-m.typing))
  (add-to-list 'matrix-client-input-filters 'matrix-client-send-to-current-room)
  (add-to-list 'matrix-client-input-filters 'matrix-client-input-filter-emote)
  (add-to-list 'matrix-client-input-filters 'matrix-client-input-filter-join)
  (add-to-list 'matrix-client-input-filters 'matrix-client-input-filter-leave))

(defmacro defmatrix-client-handler (msgtype varlist body)
  "Create an matrix-client-handler.

This macro generates a standard function which provides some
standard variables that each event handler can use to render an
event sanely.  It also sets [`inhibit-read-only'] to true to
allow you to freely render in to the buffer.

MSGTYPE is the type of the message to handle.

Provided Variables:

- `room-id': the Matrix room id the message is intended for
- `room-buf': the buffer tied to the Matrix room which the
  message is intended for.
- Any other variables in VARLIST are provided as well.

BODY is the function itself.  See, for example,
[`matrix-client-handler-m.presence'] for an example of what this looks
like."
  (let ((fname (intern (format "matrix-client-handler-%s" msgtype))))
    `(defun ,fname (data)
       (let* ((inhibit-read-only t)
              (room-id (matrix-get 'room_id data))
              (room-buf (matrix-get room-id matrix-client-active-rooms))
              ,@varlist)
         (with-current-buffer room-buf
           (save-excursion
             (goto-char (point-max))
             (forward-line -1)
             (end-of-line)
             ,@body))))))

(defmatrix-client-handler "m.room.message"
  ((content (matrix-get 'content data))
   (msg-type (matrix-get 'msgtype content)))
  ((insert-read-only "\n")
   (insert-read-only (format "📩 %s %s> "
                             (format-time-string "[%T]" (seconds-to-time (/ (matrix-get 'origin_server_ts data) 1000)))
                             (matrix-client-displayname-from-user-id (matrix-get 'user_id data))) face matrix-client-metadata)
   (when content
     (cond ((string-equal "m.emote" msg-type)
            (insert-read-only "* ")
            (insert-read-only (matrix-get 'body content)))
           ((string-equal "m.image" msg-type)
            (insert-read-only (matrix-get 'body content))(insert-read-only (matrix-get 'body content))
            (insert-read-only ": ")
            (insert-read-only (matrix-transform-mxc-uri (matrix-get 'url content))))
           (t
            (insert-read-only (matrix-get 'body content)))))))

(defmatrix-client-handler "m.lightrix.pattern"
  ((content (matrix-get 'content data)))
  ((insert "\n")
   (insert-read-only (format "🌄 %s --> " (matrix-client-displayname-from-user-id (matrix-get 'user_id data)))
                     face matrix-client-metadata)     
   (insert-read-only (matrix-get 'pattern content))))

(defmatrix-client-handler "m.room.member"
  ((content (matrix-get 'content data))
   (user-id (matrix-get 'user_id data))
   (membership (matrix-get 'membership content))
   (display-name (matrix-get 'displayname content)))
  ((unless (boundp 'matrix-client-room-membership)
     (set (make-local-variable 'matrix-client-room-membership) '()))
   (cond ((string-equal "join" membership)
          (add-to-list 'matrix-client-room-membership (cons user-id content)))
         ((or (string-equal "leave" membership) (string-equal "ban" membership))
          (set (make-local-variable 'matrix-client-room-membership)
               (matrix-client-filter (lambda (item)
                                       (string-equal user-id (car item)))
                                     matrix-client-room-membership))))
   (when matrix-client-render-membership
     (insert-read-only "\n")
     (insert-read-only (format "🚪 %s (%s) --> %s" display-name user-id membership) face matrix-client-metadata))))

(defun matrix-client-handler-m.presence (data)
  (let* ((inhibit-read-only t)
         (content (matrix-get 'content data))
         (user-id (matrix-get 'user_id content))
         (presence (matrix-get 'presence content))
         (display-name (matrix-get 'displayname content)))
    (with-current-buffer (get-buffer-create "*matrix-events*")
      (when matrix-client-render-presence
        (end-of-buffer)
        (insert-read-only "\n")
        (insert-read-only (format "🚚 %s (%s) --> %s" display-name user-id presence) face matrix-client-metadata)))))

(defmatrix-client-handler "m.room.name"
  ()
  ((set (make-local-variable 'matrix-client-room-name) (matrix-get 'name (matrix-get 'content data)))
   (cond (matrix-client-room-name
          (rename-buffer matrix-client-room-name))
         ((> (length matrix-client-room-aliases) 0)
          (rename-buffer (elt matrix-client-room-aliases 0))))
   (insert-read-only "\n")
   (insert-read-only (format "📝 Room name changed --> %s" matrix-client-room-name) face matrix-client-metadata)
   (matrix-client-update-header-line)))

(defmatrix-client-handler "m.room.aliases"
  ()
  ((set (make-local-variable 'matrix-client-room-aliases) (matrix-get 'aliases (matrix-get 'content data)))
   (cond (matrix-client-room-name
          (rename-buffer matrix-client-room-name))
         ((> (length matrix-client-room-aliases) 0)
          (rename-buffer (elt matrix-client-room-aliases 0))))
   (insert-read-only "\n")
   (insert-read-only (format "📝 Room alias changed --> %s" matrix-client-room-name) face matrix-client-metadata)
   (matrix-client-update-header-line)))

(defmatrix-client-handler "m.room.topic"
  ()
  ((set (make-local-variable 'matrix-client-room-topic) (matrix-get 'topic (matrix-get 'content data)))
   (insert-read-only "\n")
   (insert-read-only (format "✏ Room topic changed --> %s" matrix-client-room-topic) face matrix-client-metadata)
   (matrix-client-update-header-line)))

(defun matrix-client-handler-m.typing (data)
  (with-current-buffer (matrix-get (matrix-get 'room_id data) matrix-client-active-rooms)
    (set (make-local-variable 'matrix-client-room-typers) (matrix-get 'user_ids (matrix-get 'content data)))
    (matrix-client-update-header-line)))

(defun matrix-client-displayname-from-user-id (user-id)
  "Get the Display name for a USER-ID."
  (let* ((userdata (cdr (assoc user-id matrix-client-room-membership))))
    (or (matrix-get 'displayname userdata)
        user-id)))

(defun matrix-client-input-filter-join (text)
  "Input filter to handle JOINs.  Filters TEXT."
  (if (string-match "^/j\\(oin\\)? +\\(.*\\)" text)
      (progn
        (let ((room (substring text (match-beginning 2) (match-end 2))))
          (matrix-client-set-up-room
           (matrix-sync-room
            (matrix-join-room room))))
        nil)
    text))

(defun matrix-client-input-filter-leave (text)
  "Input filter to handle LEAVEs.  Filters TEXT."
  (if (and (string-match "^/leave.*" text)
           (matrix-leave-room matrix-client-room-id))
      (progn
        (kill-buffer)
        nil)
    text))

(defun matrix-client-input-filter-part (text)
  "Input filter to handle PARTs.  Filters TEXT."
  (if (string-match "^/part.*" text)
      (progn
        (matrix-leave-room matrix-client-room-id)
        nil)
    text))

(defun matrix-client-input-filter-emote (text)
  "Input filter to handle emotes.  Filters TEXT."
  (if (string-match "^/me +\\(.*\\)" text)
      (let ((emote (substring text (match-beginning 1) (match-end 1))))
        (matrix-send-event matrix-client-room-id "m.room.message"
                           `(("msgtype" . "m.emote")
                             ("body" . ,emote)))
        nil)
    text))

(provide 'matrix-client-handlers)
;;; matrix-client-handlers.el ends here
