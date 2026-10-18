; Optional SGP sprite backend. One ordered command list per frame.
; CPU expands sprite rows into RAM (reused with SGP_CACHE); SGP performs
; transparent copies. CPU erase/edge clipping and three pages are unchanged.
; Command format follows vaeg/demos/sgp-pseudo-sprite (16-colour variant).

sgp_begin:      pusha
                push es
                push cs
                pop es
                mov di,sgp_commands
                mov ax,3                ; SET_WORK, writable 58 bytes
                stosw
                mov si,sgp_work
                call sgp_address
                stosw
                mov ax,dx
                stosw
                mov [cs:sgp_tail],di
                mov word [cs:sgp_pixels_next],sgp_pixels
%ifdef SGP_CACHE
                call sgp_cache_begin
%endif
                pop es
                popa
                ret

; CS:SI -> physical DX:AX, preserves BX,SI,DI,BP.
sgp_address:    mov ax,cs
sgp_address_seg:
                xor dx,dx
                mov cx,4
.shift:         shl ax,1
                rcl dx,1
                loop .shift
                add ax,si
                adc dx,0
                ret

; DI = original CPU destination byte offset; d_* retain source dimensions.
sgp_queue:      pusha
                push es
                mov [cs:sgp_destination],di
                push cs
                pop es
                mov di,[cs:sgp_tail]
                mov ax,4                ; SET_SOURCE
                stosw
                mov ax,1                ; 4 bpp, start dot 0
                stosw
                mov ax,[cs:d_groups]
                shl ax,2                ; includes transparent odd-dot padding
                stosw
                mov ax,[cs:d_rows]
                stosw
                mov ax,12               ; word/4-byte aligned RAM row pitch
                stosw
%ifdef SGP_CACHE
                mov si,[cs:sgp_source_off]
                mov ax,[cs:sgp_source_seg]
                call sgp_address_seg
%else
                mov si,[cs:sgp_pixels_next]
                call sgp_address
%endif
                stosw
                mov ax,dx
                stosw
                mov ax,5                ; SET_DESTINATION
                stosw
                mov ax,[cs:sgp_destination]
                and ax,1                ; SGP base is word aligned
                shl ax,5                ; odd byte -> start dot 2
                or ax,1
                stosw
                mov ax,[cs:d_groups]
                shl ax,2
                stosw
                mov ax,[cs:d_rows]
                stosw
                mov ax,LINE_BYTES
                stosw
                ; CPU aperture A0000h maps to SGP GVRAM 200000h.
                mov ax,[cs:draw_seg]
                sub ax,0a000h
                xor dx,dx
                mov cx,4
.address:       shl ax,1
                rcl dx,1
                loop .address
                add ax,[cs:sgp_destination]
                adc dx,20h
                and ax,0fffeh
                stosw
                mov ax,dx
                stosw
                mov ax,7                ; BITBLT, source zero transparent
                stosw
                mov ax,0105h
                stosw
                mov [cs:sgp_tail],di
                add word [cs:sgp_pixels_next],192
                pop es
                popa
                ret

sgp_flush:      pusha
                push es
                push cs
                pop es
                mov di,[cs:sgp_tail]
                mov ax,1                ; END
                stosw
                mov dx,0580h
                mov al,10h              ; CPU-data write mode, as BIOS/demo
                out dx,al
                mov si,sgp_commands
                call sgp_address
                mov bx,dx
                mov dx,0500h
                out dx,ax
                add dx,2
                mov ax,bx
                out dx,ax
                add dx,2
                xor al,al
                out dx,al
                add dx,2
                mov al,1
                out dx,al
                mov cx,0ffffh
.wait:          in al,dx
                test al,1
                jz .done
                loop .wait
                ; Fail closed: never reuse RAM or display an unfinished page.
                mov byte [cs:sgp_failed],1
                cli
.failed:        hlt
                jmp .failed
.done:          pop es
                popa
                ret

                align 2
sgp_work        times 58 db 0
sgp_commands    times (6 + 16 * 32 + 2) db 0
sgp_pixels      times (16 * 192) db 0
sgp_tail        dw 0
sgp_pixels_next dw 0
sgp_destination dw 0
sgp_failed      db 0
%ifdef SGP_CACHE
%include "src/game/sgp_cache.inc"
%endif
