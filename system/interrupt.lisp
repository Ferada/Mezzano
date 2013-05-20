(in-package :sys.int)

(defvar *isa-pic-shadow-mask* #xFFFF)

(defun isa-pic-irq-mask (irq)
  (check-type irq (integer 0 16))
  (logtest (ash 1 irq) *isa-pic-shadow-mask*))

(defun (setf isa-pic-irq-mask) (value irq)
  (check-type irq (integer 0 16))
  (setf (ldb (byte 1 irq) *isa-pic-shadow-mask*)
        (if value 1 0))
  (if (< irq 8)
      ;; Master PIC.
      (setf (io-port/8 #x21) (ldb (byte 8 0) *isa-pic-shadow-mask*))
      ;; Slave PIC.
      (setf (io-port/8 #xA1) (ldb (byte 8 8) *isa-pic-shadow-mask*)))
  value)

(defvar *isa-pic-handlers* (make-array 16 :initial-element nil))
(defvar *isa-pic-stack-groups* (make-array 16 :initial-element nil :area :static))
(defvar *isa-pic-base-handlers* (make-array 16 :initial-element nil))

;;; RBP, RAX, RCX pushed on stack.
;;; RCX = IRQ number as fixnum.
(define-lap-function %%isa-pic-common ()
  ;; Save the current state.
  (sys.lap-x86:push :rdx)
  (sys.lap-x86:push :rsi)
  (sys.lap-x86:push :rdi)
  (sys.lap-x86:mov64 (:lsp -8) nil)
  (sys.lap-x86:mov64 (:lsp -16) nil)
  (sys.lap-x86:mov64 (:lsp -24) nil)
  (sys.lap-x86:mov64 (:lsp -32) nil)
  (sys.lap-x86:mov64 (:lsp -40) nil)
  (sys.lap-x86:mov64 (:lsp -48) nil)
  (sys.lap-x86:mov64 (:lsp -56) nil)
  (sys.lap-x86:sub64 :lsp 56)
  (sys.lap-x86:mov64 (:lsp 0) :r8)
  (sys.lap-x86:mov64 (:lsp 8) :r9)
  (sys.lap-x86:mov64 (:lsp 16) :r10)
  (sys.lap-x86:mov64 (:lsp 24) :r11)
  (sys.lap-x86:mov64 (:lsp 32) :r12)
  (sys.lap-x86:mov64 (:lsp 40) :r13)
  (sys.lap-x86:mov64 (:lsp 48) :rbx)
  ;; Load the target stack-group.
  (sys.lap-x86:mov64 :r8 (:constant *isa-pic-stack-groups*))
  (sys.lap-x86:mov64 :r8 (:symbol-value :r8))
  (sys.lap-x86:mov64 :r8 (:r8 :rcx #.(+ 8 (- +tag-array-like+))))
  ;; Set the stack-group resumer field.
  (sys.lap-x86:mov32 :ecx #xC0000101) ; IA32_GS_BASE
  (sys.lap-x86:rdmsr)
  (sys.lap-x86:shl64 :rdx 32)
  (sys.lap-x86:or64 :rax :rdx)
  (sys.lap-x86:mov64 (:r8 #.(+ (* 11 8) (- +tag-array-like+))) :rax)
  (sys.lap-x86:mov32 :ecx 8)
  (sys.lap-x86:mov64 :r13 (:constant %%stack-group-resume))
  (sys.lap-x86:call (:symbol-function :r13))
  (sys.lap-x86:mov64 :r8 (:lsp 0))
  (sys.lap-x86:mov64 :r9 (:lsp 8))
  (sys.lap-x86:mov64 :r10 (:lsp 16))
  (sys.lap-x86:mov64 :r11 (:lsp 24))
  (sys.lap-x86:mov64 :r12 (:lsp 32))
  (sys.lap-x86:mov64 :r13 (:lsp 40))
  (sys.lap-x86:mov64 :rbx (:lsp 48))
  (sys.lap-x86:add64 :lsp 56)
  (sys.lap-x86:mov64 (:lsp -8) nil)
  (sys.lap-x86:mov64 (:lsp -16) nil)
  (sys.lap-x86:mov64 (:lsp -24) nil)
  (sys.lap-x86:mov64 (:lsp -32) nil)
  (sys.lap-x86:mov64 (:lsp -40) nil)
  (sys.lap-x86:mov64 (:lsp -48) nil)
  (sys.lap-x86:mov64 (:lsp -56) nil)
  (sys.lap-x86:pop :rdi)
  (sys.lap-x86:pop :rsi)
  (sys.lap-x86:pop :rdx)
  (sys.lap-x86:pop :rcx)
  (sys.lap-x86:pop :rax)
  (sys.lap-x86:pop :rbp)
  (sys.lap-x86:iret))

(defun isa-pic-common (irq)
  (loop
     (let ((handler (svref *isa-pic-handlers* irq)))
       (when handler
         (funcall handler)))
     (setf (io-port/8 #x20) #x20)
     (when (>= irq 8)
       (setf (io-port/8 #xA0) #x20))
     (stack-group-return)))

(macrolet ((doit ()
             (let ((forms '(progn)))
               (dotimes (i 16)
                 (push `(irq-handler ,i) forms))
               (nreverse forms)))
           (irq-handler (n)
             (let ((sym (intern (format nil "%%IRQ~D-thunk" n))))
               `(progn
                  (define-lap-function ,sym ()
                    (sys.lap-x86:push :rbp)
                    (sys.lap-x86:mov64 :rbp :rsp)
                    (sys.lap-x86:push :rax)
                    (sys.lap-x86:push :rcx)
                    (sys.lap-x86:mov32 :ecx ,(* n 8))
                    (sys.lap-x86:mov64 :rax (:constant %%isa-pic-common))
                    (sys.lap-x86:jmp (:symbol-function :rax)))
                  (setf (aref *isa-pic-base-handlers* ,n) #',sym)
                  (setf (aref *isa-pic-stack-groups* ,n) (make-stack-group ,(format nil "IRQ~D" n)
                                                                           :control-stack-size 512
                                                                           :data-stack-size 512
                                                                           :binding-stack-size 32))
                  (stack-group-preset-no-interrupts (aref *isa-pic-stack-groups* ,n) #'isa-pic-common ,n)))))
  (doit))

(defun isa-pic-interrupt-handler (irq)
  (aref *isa-pic-handlers* irq))

(defun (setf isa-pic-interrupt-handler) (value irq)
  (check-type value (or null function))
  (setf (aref *isa-pic-handlers* irq) value))

(defconstant +isa-pic-interrupt-base+ #x30)

(defun set-idt-entry (entry &key (offset 0) (segment #x0008)
                      (present t) (dpl 0) (ist nil)
                      (interrupt-gate-p t))
  (check-type entry (unsigned-byte 8))
  (check-type offset (signed-byte 64))
  (check-type segment (unsigned-byte 16))
  (check-type dpl (unsigned-byte 2))
  (check-type ist (or null (unsigned-byte 3)))
  (let ((value 0))
    (setf (ldb (byte 16 48) value) (ldb (byte 16 16) offset)
          (ldb (byte 1 47) value) (if present 1 0)
          (ldb (byte 2 45) value) dpl
          (ldb (byte 4 40) value) (if interrupt-gate-p
                                      #b1110
                                      #b1111)
          (ldb (byte 3 16) value) (or ist 0)
          (ldb (byte 16 16) value) segment
          (ldb (byte 16 0) value) (ldb (byte 16 0) offset))
    (setf (aref *idt* (* entry 2)) value
          (aref *idt* (1+ (* entry 2))) (ldb (byte 32 32) offset))))

(defun init-isa-pic ()
  ;; Hook into the IDT.
  (dotimes (i 16)
    (set-idt-entry (+ +isa-pic-interrupt-base+ i)
                   :offset (lisp-object-address (aref *isa-pic-base-handlers* i))))
  ;; Initialize the ISA PIC.
  (setf (io-port/8 #x20) #x11
        (io-port/8 #xA0) #x11
        (io-port/8 #x21) +isa-pic-interrupt-base+
        (io-port/8 #xA1) (+ +isa-pic-interrupt-base+ 8)
        (io-port/8 #x21) #x04
        (io-port/8 #xA1) #x02
        (io-port/8 #x21) #x01
        (io-port/8 #xA1) #x01
        ;; Mask all IRQs except for the cascade IRQ (2).
        (io-port/8 #x21) #xFF
        (io-port/8 #xA1) #xFF
        *isa-pic-shadow-mask* #xFFFF
        (isa-pic-irq-mask 2) nil))

;;; Must be run each boot, but also do it really early here in case
;;; anything turns interrupts on during cold initialization.
#+nil(add-hook '*early-initialize-hook* 'init-isa-pic)
(init-isa-pic)

(defun ldb-exception (stack-frame)
  (mumble-string "In LDB.")
  (dotimes (i 32)
    (mumble-string " ")
    (mumble-hex (memref-unsigned-byte-64 stack-frame i)))
  (mumble-string ". Halted.")
  (loop (%hlt)))

(defvar *exception-base-handlers* (make-array 32 :initial-element nil))
(define-lap-function %%exception ()
  ;; RAX already pushed.
  (sys.lap-x86:push :rbx)
  (sys.lap-x86:push :rcx)
  (sys.lap-x86:push :rdx)
  (sys.lap-x86:push :rbp)
  (sys.lap-x86:push :rsi)
  (sys.lap-x86:push :rdi)
  (sys.lap-x86:push :r8)
  (sys.lap-x86:push :r9)
  (sys.lap-x86:push :r10)
  (sys.lap-x86:push :r11)
  (sys.lap-x86:push :r12)
  (sys.lap-x86:push :r13)
  (sys.lap-x86:push :r14)
  (sys.lap-x86:push :r15)
  (sys.lap-x86:mov64 :r8 :rsp)
  (sys.lap-x86:shl64 :r8 3)
  (sys.lap-x86:test64 :rsp #b1000)
  (sys.lap-x86:jz already-aligned)
  (sys.lap-x86:push 0)
  already-aligned
  (sys.lap-x86:mov32 :ecx 8)
  ;; FIXME: Should switch to a secondary data stack.
  (sys.lap-x86:mov64 :r13 (:constant ldb-exception))
  (sys.lap-x86:call (:symbol-function :r13))
  (sys.lap-x86:mov64 :rsp :r8)
  (sys.lap-x86:pop :r15)
  (sys.lap-x86:pop :r14)
  (sys.lap-x86:pop :r13)
  (sys.lap-x86:pop :r12)
  (sys.lap-x86:pop :r11)
  (sys.lap-x86:pop :r10)
  (sys.lap-x86:pop :r9)
  (sys.lap-x86:pop :r8)
  (sys.lap-x86:pop :rdi)
  (sys.lap-x86:pop :rsi)
  (sys.lap-x86:pop :rbp)
  (sys.lap-x86:pop :rdx)
  (sys.lap-x86:pop :rcx)
  (sys.lap-x86:pop :rbx)
  (sys.lap-x86:pop :rax)
  (sys.lap-x86:add64 :rsp 16)
  (sys.lap-x86:iret))

(eval-when (:compile-toplevel :load-toplevel :execute)
  (defparameter *exception-names*
    #("Divide-Error"
      "Debug"
      "NMI"
      "Breakpoint"
      "Overflow"
      "BOUND-Range-Exceeded"
      "Invalid-Opcode"
      "Device-Not-Available"
      "Double-Fault"
      "Coprocessor-Segment-Overrun"
      "Invalid-TSS"
      "Segment-Not-Present"
      "Stack-Segment-Fault"
      "General-Protection-Fault"
      "Page-Fault"
      "Exception-15"
      "Math-Fault"
      "Alignment-Check"
      "Machine-Check"
      "SIMD-Floating-Point-Exception"
      "Exception-20"
      "Exception-21"
      "Exception-22"
      "Exception-23"
      "Exception-24"
      "Exception-25"
      "Exception-26"
      "Exception-27"
      "Exception-28"
      "Exception-29"
      "Exception-30"
      "Exception-31")))

(macrolet ((doit ()
             (let ((forms '(progn)))
               (dotimes (i 32)
                 (push `(exception-handler ,i) forms))
               (nreverse forms)))
           (exception-handler (n)
             (let ((sym (intern (format nil "%%~A-thunk" (aref *exception-names* n)))))
               `(progn
                  (define-lap-function ,sym ()
                    ;; Some exceptions do not push an error code.
                    ,@(unless (member n '(8 10 11 12 13 14 17))
                              `((sys.lap-x86:push 0)))
                    (sys.lap-x86:push ,n)
                    (sys.lap-x86:push :rax)
                    (sys.lap-x86:mov64 :rax (:constant %%exception))
                    (sys.lap-x86:jmp (:symbol-function :rax)))
                  (setf (aref *exception-base-handlers* ,n) #',sym)
                  (set-idt-entry ,n :offset (lisp-object-address #',sym))))))
  (doit))

(defmacro define-interrupt-handler (name lambda-list &body body)
  `(progn (setf (get ',name 'interrupt-handler)
                (lambda ,lambda-list
                  (declare (system:lambda-name (interrupt-handler ,name)))
                  ,@body))
          ',name))

(defun make-interrupt-handler (name &rest arguments)
  (setf argument (copy-list-in-area arguments :static))
  (let* ((fn (get name 'interrupt-handler))
         (thunk (lambda () (apply fn arguments))))
    ;; Grovel inside the closure and move the environment
    ;; object to static space.
    (let ((the-lambda (function-pool-object thunk 0))
          (the-env (function-pool-object thunk 1)))
      (make-closure the-lambda
                    (make-array (length the-env)
                                :initial-contents the-env
                                :area :static)))))

(define-lap-function %%interrupt-break-thunk ()
  ;; Control will return to the common PIC code.
  ;; All registers can be smashed here, aside from the stack regs.
  ;; Align the control stack
  (sys.lap-x86:mov64 :rax :csp)
  (sys.lap-x86:test64 :csp 8)
  (sys.lap-x86:jz over-align)
  (sys.lap-x86:add64 :csp 8)
  over-align
  ;; Save the old CSP and CFP.
  (sys.lap-x86:push :rax)
  (sys.lap-x86:push :cfp)
  ;; Skip one control frame. The debugger can't handle frames created
  ;; by interrupt handlers.
  (sys.lap-x86:mov64 :cfp (:cfp))
  ;; Call break.
  (sys.lap-x86:xor32 :ecx :ecx)
  (sys.lap-x86:mov64 :r13 (:constant break))
  (sys.lap-x86:call (:symbol-function :r13))
  (sys.lap-x86:mov64 :lsp :rbx)
  ;; Restore stack regs.
  (sys.lap-x86:pop :cfp)
  (sys.lap-x86:pop :rax)
  (sys.lap-x86:mov64 :csp :rax)
  ;; All done.
  (sys.lap-x86:ret))

(defun signal-break-from-interrupt ()
  "Configure the resumer stack group so it will call BREAK when resumed."
  (let* ((target (stack-group-resumer (current-stack-group)))
         (sg-pointer (ash (%pointer-field target) 4))
         (state (memref-t sg-pointer 2))
         (csp (memref-unsigned-byte-64 sg-pointer 3))
         (original-csp csp))
    (when (not (logtest state +stack-group-uninterruptable+))
      ;; TARGET's control stack looks like:
      ;;  +0 CFP
      ;;  +8 LFP
      ;; +16 LSP
      ;; +24 RFlags
      ;; +32 RIP
      ;; 16 byte alignment not guaranteed.
      ;; Rewrite it so it looks like:
      ;;  +0 CFP
      ;;  +8 LFP
      ;; +16 LSP
      ;; +24 RFlags (with IF set)
      ;; +32 break-thunk
      ;; +40 RIP
      ;; and is aligned.
      (decf csp 8)
      (setf (memref-unsigned-byte-64 csp 0) (memref-unsigned-byte-64 original-csp 0)) ; CFP
      (setf (memref-unsigned-byte-64 csp 1) (memref-unsigned-byte-64 original-csp 1)) ; LFP
      (setf (memref-unsigned-byte-64 csp 2) (memref-unsigned-byte-64 original-csp 2)) ; LSP
      (setf (memref-unsigned-byte-64 csp 3) (logior (memref-unsigned-byte-64 original-csp 3) #x200)) ; RFlags
      (setf (memref-t csp 4) #'%%interrupt-break-thunk) ; thunk
      (setf (memref-unsigned-byte-64 sg-pointer 3) csp))))