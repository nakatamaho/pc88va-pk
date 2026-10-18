; Copyright (c) 2026 Nakata Maho
;
; Redistribution and use in source and binary forms, with or without
; modification, are permitted provided that the following conditions
; are met:
; 1. Redistributions of source code must retain the above copyright
;    notice, this list of conditions and the following disclaimer.
; 2. Redistributions in binary form must reproduce the above copyright
;    notice, this list of conditions and the following disclaimer in the
;    documentation and/or other materials provided with the distribution.
;
; THIS SOFTWARE IS PROVIDED BY THE AUTHOR "AS IS" AND ANY EXPRESS OR
; IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES
; OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED.
; IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR ANY DIRECT, INDIRECT,
; INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING,
; BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF
; USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON
; ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
; (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF
; THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
;
; DOS-side optional FM cache and quick integer harmonic synthesis.
; Included by pk.asm. DS = CS, ES = PAY on entry/exit of fm_prepare.
; See tools/fmdata.py for the bit-exact reference and cache format.

FM_BYTES        equ 144
FM_HEADER       equ 20
FM_FILE_BYTES   equ FM_HEADER + FM_BYTES
FM_FULL_SCALE   equ 15240

fm_prepare:     mov byte [es:P_FM_READY],0
                cmp byte [force_ssg],0
                jne .done
                ; Fail disk critical errors rather than showing Abort/Retry.
                mov ax,3524h
                int 21h
                mov [fm_old24],bx
                mov [fm_old24 + 2],es
                mov dx,fm_critical
                mov ax,2524h
                int 21h
                cmp byte [force_fm],0
                jne .generate
                call fm_read
                jc .generate
                mov dx,fm_s_loaded
                call print
                jmp .use
.generate:      cmp byte [wave_rom + 8],0
                jne .calculate
                mov dx,fm_s_no_wave
                call print
                jmp .restore
.calculate:     mov dx,fm_s_calculate
                call print
                call fm_quick
                ; Reinitialise every header field after a failed read.
                mov si,fm_header
                mov di,fm_file
                push ds
                pop es
                mov cx,16
                rep movsb
                mov si,fm_file + FM_HEADER
                mov cx,FM_BYTES
                call crc32
                mov [fm_file + 16],ax
                mov [fm_file + 18],dx
                call fm_save
                mov dx,fm_s_saved
                jnc .notice
                mov dx,fm_s_write
.notice:        call print
.use:           mov ax,PAY
                mov es,ax
                mov di,P_FM_VOICES
                mov si,fm_file + FM_HEADER
                mov cx,FM_BYTES
                rep movsb
                mov byte [es:P_FM_READY],1
.restore:       push ds
                lds dx,[fm_old24]
                mov ax,2524h
                int 21h
                pop ds
.done:          mov ax,PAY
                mov es,ax
                ret

fm_critical:    mov al,3                  ; DOS critical-error action: Fail
                iret

; Path prefix is the same as the ROM directory; SI is a null-terminated name.
fm_path:        mov di,[path_end]
.copy:          lodsb
                stosb                   ; ES must equal CS here
                or al,al
                jnz .copy
                mov dx,path
                ret

fm_read:        push ds
                pop es
                mov si,fm_name
                call fm_path
                mov ax,3d00h
                int 21h
                jc .bad
                mov bx,ax
                mov dx,fm_file
                mov cx,FM_FILE_BYTES + 1 ; reject trailing data, including one byte
                mov ah,3fh
                int 21h
                pushf
                push ax
                mov ah,3eh
                int 21h
                pop ax
                popf
                jc .bad
                cmp ax,FM_FILE_BYTES
                jne .bad
                mov si,fm_file
                mov di,fm_header
                mov cx,6                ; magic and format version
                repe cmpsb
                jne .bad
                mov ax,[fm_file + 6]     ; generator 1: quick; 2: host fitted
                dec ax
                cmp ax,1
                ja .bad
                mov si,fm_file + 8
                mov di,fm_header + 8
                mov cx,8                ; source CRC, data size and reserved
                repe cmpsb
                jne .bad
                mov si,fm_file + FM_HEADER
                mov cx,FM_BYTES
                call crc32
                cmp ax,[fm_file + 16]
                jne .bad
                cmp dx,[fm_file + 18]
                jne .bad
                mov si,fm_file + FM_HEADER
                mov cx,16
.voice:         lodsb
                cmp al,63               ; FB <= 7, ALG <= 7
                ja .bad
                mov bp,4
.op:            lodsw
                cmp al,15               ; MUL, no detune
                ja .bad
                cmp ah,127              ; TL
                ja .bad
                dec bp
                jnz .op
                loop .voice
                clc
                ret
.bad:           stc
                ret

; Write to a temporary file first. Never publish a partial cache as valid.
; A failed save is nonfatal: the generated data remains usable in memory.
fm_save:        mov si,fm_temp
                call fm_path
                xor cx,cx
                mov ah,3ch
                int 21h
                jc .bad
                mov bx,ax
                mov dx,fm_file
                mov cx,FM_FILE_BYTES
                mov ah,40h
                int 21h
                pushf
                push ax
                mov ah,3eh
                int 21h
                jc .close_bad
                pop ax
                popf
                jc .cleanup
                cmp ax,FM_FILE_BYTES
                jne .cleanup
                mov si,fm_name
                call fm_path
                mov ah,41h              ; remove old invalid/replaced cache
                int 21h
                jnc .rename
                cmp ax,2                ; file not found is expected first time
                jne .cleanup
.rename:        ; DOS rename takes two paths; copy the final one separately.
                mov si,path
                mov di,fm_final_path
.copy:          lodsb
                stosb
                or al,al
                jnz .copy
                mov si,fm_temp
                call fm_path
                mov di,fm_final_path
                mov ah,56h
                int 21h
                jnc .done
                jmp .cleanup
.close_bad:     pop ax
                popf
.cleanup:       mov si,fm_temp
                call fm_path
                mov ah,41h
                int 21h
.bad:           stc
.done:          ret

; Four strongest harmonics, integer DFT at 32 points, with peak-safe
; additive amplitudes. Same voice in LOW/HIGH. No fitted model or feedback.
fm_quick:       mov ax,SCRATCH
                mov es,ax
                mov word [fm_wave_at],S_WAVES
                mov word [fm_dest],fm_file + FM_HEADER
.wave:          mov bp,1                ; harmonic 1..15
.harmonic:      mov word [fm_real],0
                mov word [fm_imag],0
                xor si,si               ; phase j*k modulo 32
                xor di,di               ; sample j
.sample:        mov bx,[fm_wave_at]
                mov al,[es:bx + di]
                and ax,15
                sub ax,8
                mov [fm_sample],ax
                mov bx,si
                shl bx,1
                mov ax,[fm_sine + bx]
                imul word [fm_sample]
                add [fm_imag],ax
                add bx,16               ; cos = sin shifted by 8 samples
                and bx,63
                mov ax,[fm_sine + bx]
                imul word [fm_sample]
                add [fm_real],ax
                add si,bp
                and si,31
                inc di
                cmp di,32
                jb .sample
                mov ax,[fm_real]
                imul ax
                mov [fm_power],ax
                mov [fm_power + 2],dx
                mov ax,[fm_imag]
                imul ax
                add ax,[fm_power]
                adc dx,[fm_power + 2]
                call fm_isqrt
                mov si,bp
                dec si
                shl si,1
                mov [fm_harmonics + si],bx
                inc bp
                cmp bp,16
                jb .harmonic
                xor di,di               ; pick four, ties by lowest harmonic
                mov word [fm_total],0
.pick:          mov bx,0ffffh
                xor dx,dx
                xor si,si
.scan:          mov ax,[fm_harmonics + si]
                cmp ax,0ffffh
                je .next
                cmp bx,0ffffh
                je .best
                cmp ax,dx
                jbe .next
.best:          mov dx,ax
                mov bx,si
.next:          add si,2
                cmp si,30
                jb .scan
                mov word [fm_harmonics + bx],0ffffh
                mov [fm_selected + di],dx
                add [fm_total],dx
                shr bx,1
                inc bx
                mov [fm_muls + di],bx
                add di,2
                cmp di,8
                jb .pick
                mov di,[fm_dest]
                mov byte [di],7          ; ALG 7, FB 0
                inc di
                xor bp,bp
.level:         mov ax,[fm_selected + bp]
                cmp word [fm_total],FM_FULL_SCALE
                jbe .attenuate
                mov bx,FM_FULL_SCALE
                mul bx
                div word [fm_total]
.attenuate:     mov [fm_sample],ax
                xor bx,bx
                mov dx,0ffffh
                xor si,si
.tl:            mov ax,[fm_amplitudes + bx]
                sub ax,[fm_sample]
                jnc .absolute
                neg ax
.absolute:      cmp ax,dx
                jae .later
                mov dx,ax
                mov si,bx
.later:         add bx,2
                cmp bx,256
                jb .tl
                mov ax,[fm_muls + bp]
                mov [di],al
                shr si,1
                mov ax,si
                mov [di + 1],al
                add di,2
                add bp,2
                cmp bp,8
                jb .level
                ; Duplicate the voice for the other pitch range.
                mov si,[fm_dest]
                mov cx,9
.duplicate:     lodsb
                mov [di],al
                inc di
                loop .duplicate
                mov [fm_dest],di
                add word [fm_wave_at],32
                mov ah,02h
                mov dl,'.'
                int 21h
                cmp word [fm_wave_at],S_WAVES + 256
                jae .done
                jmp .wave
.done:          push ds
                pop es
                ret

; Unsigned floor(sqrt(DX:AX)) in BX. At most 16 trial multiplications.
fm_isqrt:       mov [fm_power],ax
                mov [fm_power + 2],dx
                xor bx,bx
                mov cx,8000h
.bit:           mov di,bx
                or di,cx
                mov ax,di
                mul di
                cmp dx,[fm_power + 2]
                ja .next
                jb .accept
                cmp ax,[fm_power]
                ja .next
.accept:        mov bx,di
.next:          shr cx,1
                jnz .bit
                ret

fm_name         db 'FMVOICE.DAT',0
fm_temp         db 'FMVOICE.$$$',0
fm_header       db 'PKFM'
                dw 1,1                  ; format 1, quick generator
                dd 0a9cc86bfh           ; waveform PROM CRC-32
                dw FM_BYTES,0
fm_file         times FM_FILE_BYTES + 1 db 0
fm_old24        dd 0
fm_s_loaded     db 'FM: loaded FMVOICE.DAT.',13,10,'$'
fm_s_no_wave    db 'FM cache/wave PROM unavailable; using SSG.',13,10,'$'
fm_s_calculate  db 'FM: generating quick harmonic voices (8 waves)',13,10,'$'
fm_s_saved      db 13,10,'FMVOICE.DAT saved.',13,10,'$'
fm_s_write      db 13,10,'Cannot save FMVOICE.DAT; using voices in memory.',13,10,'$'

; Mathematical tables generated without ROM input.
%include "fmtables.inc"
