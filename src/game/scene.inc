; Bulk background updates are completed on a hidden page before display.
; No game-state patch: the original program and sound keep running.
; scene_begin runs before show_page; scene_end runs after rendering.
; render marks a page incomplete as soon as its budget is exhausted.
; This happens before that page's next presentation: no separate preflight
; scan is needed. A full render sweep supplies the completion signal too.
scene_begin:    mov byte [cs:scene_complete],0
                cmp byte [cs:scene_hold],0
                jne .held
                clc                     ; show completed page, select next once
                ret
.held:          stc                     ; continue on the same hidden page
                ret

; Before normal page catch-up, copy the complete background for a page
; whose bounded update history was invalidated by a held transaction.
scene_page:     push ax
                push bx
                mov bl,[cs:back]
                xor bh,bh
                cmp byte [cs:scene_rebuild + bx],0
                je .done
                mov byte [cs:scene_rebuild + bx],0
                pusha
                push ds
                push es
                mov ds,[cs:bg_seg]
                mov es,[cs:draw_seg]
                xor si,si
                xor di,di
                mov cx,LINES * LINE_BYTES / 2
                rep movsw
                pop es
                pop ds
                popa
.done:          pop bx
                pop ax
                ret

scene_end:      cmp byte [cs:scene_hold],0
                je .done
                cmp byte [cs:scene_complete],0
                je .busy
                inc byte [cs:scene_quiet]
                cmp byte [cs:scene_quiet],2
                jb .done
                mov byte [cs:scene_hold],0
                ; Queues cannot retain an arbitrarily large scene update.
                ; Refresh the other hidden pages when next selected instead.
                push ax
                push bx
                xor bx,bx
.invalidate:    mov byte [cs:scene_rebuild + bx],1
                inc bx
                cmp bx,PAGES
                jb .invalidate
                mov bl,[cs:back]
                xor bh,bh
                mov byte [cs:scene_rebuild + bx],0
                xor bx,bx
.clear:         mov word [cs:queue_count + bx],0
                add bx,2
                cmp bx,PAGES * 2
                jb .clear
                pop bx
                pop ax
                jmp .done
.busy:          mov byte [cs:scene_quiet],0
.done:          ret

scene_reset:    mov byte [cs:scene_hold],0
                mov byte [cs:scene_quiet],0
                mov byte [cs:scene_complete],0
                mov word [cs:scene_rebuild],0
                mov byte [cs:scene_rebuild + 2],0
                ret
scene_complete  db 0
scene_hold      db 0
scene_quiet     db 0
scene_rebuild   times PAGES db 0
scene_display   db 0
scene_epoch     dw 0
