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
; FB1TEST: how many lines of graphics screen 1 the PC-88VA and PC-88VA2
; show in the two-screen 320x224 mode (docs/DESIGN.md, screen; FB1
; investigation).
;
; Loaded by src/boot/ipl.asm to 2000:0000; needs no ROM data.
;
; Every test sets the two-screen single-plane mode of M04's first version
; (INT 8Fh mode E00Eh, screen 1 over screen 0, colour 0 of screen 1
; transparent), draws a ruler on both screens and switches to the 15.98 kHz
; 224-line timing. Screen 0 shows on the left half (dots 0-159), screen 1 on
; the right half (dots 160-319), each in 8-line bands of alternating colour
; labelled with the band's first line number (0, 8, ..., 232). The last band
; that can be read on the right half is the last line screen 1 reaches. The
; test number is shown as that many white blocks at the top right. Any key
; reboots.
;
;   1  register readback (text): ports 0100h, 0102h, FB0 and FB1 after the
;      BIOS set-up, and again after test 2's writes
;   2  as M04's first version: FB0 and FB1 FBL = DSH = 224, DSA1 = 20000h
;   3  2, plus FB1 FBW = 160, DSP = 0 and FB0 DSP = 0
;   4  2, with the GRMODE line field set to 204 lines
;   5  2, with FB1 DSH = 240
;   6  2, with the frame-buffer writes after the SYNC command
;   7  2, with the GRMODE line field set to 400 lines

		cpu	186
		org	0

LINES		equ	224
RULER_LINES	equ	240
LINE_BYTES	equ	160
G1_SEG		equ	0c000h		; screen 1 at GVRAM 20000h (DSA1)

start:		cli
		mov	ax,cs
		mov	ds,ax
		mov	es,ax
		mov	ss,ax
		mov	sp,0fffeh
		cld
		sti
		mov	ah,2ah			; text screen
		int	83h
		mov	ax,1702h
		int	83h
		xor	dx,dx
		mov	ah,08h
		int	83h
		mov	si,s_menu
		call	puts
.key:		call	wait_key
		sub	al,'1'
		jb	.key
		cmp	al,6
		ja	.key
		mov	[test_no],al
		inc	byte [test_no]		; 1-7
		cmp	al,0
		je	readback
		jmp	run_test

; ---------------------------------------------------------------------------
; Test 1: register readback

readback:	call	mode_setup
		jc	fail
		mov	di,regs_before		; read first: the two-screen
		call	dump			; composition hides the text screen
		cli
		call	writes_base
		sti
		mov	di,regs_after
		call	dump
		mov	ax,0b00h		; text only again, as vaeg's
		int	8fh			; demos/sgp-boot/loader.asm
		mov	ax,0a00h
		int	8fh
		mov	ax,0300h
		mov	cx,0001h
		int	8fh
		push	cs
		pop	es
		mov	ax,1702h
		int	83h
		xor	dx,dx
		mov	ah,08h
		int	83h
		mov	si,s_before
		call	puts
		mov	si,regs_before
		call	print_regs
		mov	si,s_after
		call	puts
		mov	si,regs_after
		call	print_regs
		mov	si,s_key
		call	puts
		call	wait_key
		jmp	0ffffh:0000h

; Read ports 0100h, 0102h, FB0 (0200h-021Eh) and FB1 (0220h-023Eh) as
; words to DI (34 words).
dump:		mov	dx,0100h
		in	ax,dx
		stosw
		mov	dx,0102h
		in	ax,dx
		stosw
		mov	dx,0200h
		mov	cx,32
.w:		in	ax,dx
		stosw
		add	dx,2
		loop	.w
		ret

; Print the 34 words at SI: 0100h 0102h, then FB0 and FB1 in rows of 16.
print_regs:	lodsw
		call	puthex16
		call	space
		lodsw
		call	puthex16
		call	crlf
		mov	bx,2
.fb:		mov	cx,16
.w:		lodsw
		call	puthex16
		call	space
		loop	.w
		call	crlf
		dec	bx
		jnz	.fb
		ret

space:		push	ax
		mov	al,' '
		call	putc
		pop	ax
		ret

; ---------------------------------------------------------------------------
; Tests 2-7

run_test:	mov	ax,1702h		; clear the text screen
		int	83h
		call	mode_setup
		jc	fail
		mov	ax,0b01h		; graphics display on
		int	8fh
		mov	ah,16h			; as V480PAT before changing the timing
		int	84h
		mov	ax,0500h
		mov	cl,00h
		xor	bx,bx
		xor	dx,dx
		int	8fh
		mov	ax,0b01h
		int	8fh
		call	draw			; after the BIOS calls, which use GVRAM
		cli
		xor	ax,ax
		mov	dx,010ah
		out	dx,ax
		cmp	byte [test_no],6
		je	.sync
		call	writes
.sync:		mov	si,sync224
		mov	al,10h
		call	tsp_cmd
		mov	cx,14
.prm:		lodsb
		call	tsp_prm
		loop	.prm
		cmp	byte [test_no],6
		jne	.done
		call	writes
.done:		sti
		call	draw			; again, after the timing change
		call	wait_key
		jmp	0ffffh:0000h

; The test's frame-buffer and mode writes.
writes:		call	writes_base
		mov	al,[test_no]
		cmp	al,3
		jne	.t4
		mov	ax,LINE_BYTES		; FB1 FBW
		mov	dx,0224h
		out	dx,ax
		xor	ax,ax			; FB1 DSP, FB0 DSP
		mov	dx,0236h
		out	dx,ax
		mov	dx,0216h
		out	dx,ax
		ret
.t4:		cmp	al,4
		jne	.t5
		mov	dx,0100h		; GRMODE lines: 204
		in	ax,dx
		or	al,03h
		out	dx,ax
		ret
.t5:		cmp	al,5
		jne	.t7
		mov	ax,RULER_LINES		; FB1 DSH 240
		mov	dx,0232h
		out	dx,ax
		ret
.t7:		cmp	al,7
		jne	.r
		mov	dx,0100h		; GRMODE lines: 400
		in	ax,dx
		and	al,0fch
		out	dx,ax
.r:		ret

; M04's first version: FBL and DSH 224 for FB0 and FB1, DSA1 = 20000h.
writes_base:	mov	ax,LINES
		mov	dx,0206h
		out	dx,ax
		mov	dx,0212h
		out	dx,ax
		mov	dx,0226h
		out	dx,ax
		mov	dx,0232h
		out	dx,ax
		xor	ax,ax
		mov	dx,022eh
		out	dx,ax
		mov	ax,0002h
		mov	dx,0230h
		out	dx,ax
		ret

; Two screens, 320 dots, 4 bits/pixel, screen 1 over screen 0 (M04's first
; version). CF = 1 on a BIOS error.
mode_setup:	xor	ax,ax
		mov	bx,0e00eh
		mov	cx,0404h
		xor	dx,dx
		int	8fh
		or	ax,ax
		jnz	.fail
		mov	ax,0300h
		mov	cx,0034h
		int	8fh
		or	ax,ax
		jnz	.fail
		mov	di,fb_desc
		mov	ax,0100h
		mov	cx,1
		int	8fh
		or	ax,ax
		jnz	.fail
		mov	di,fb_desc
		mov	ax,0700h
		mov	cl,0
		int	8fh
		or	ax,ax
		jnz	.fail
		push	cs
		pop	es
		mov	ax,[fb_desc + 6]	; screen 0's segment
		mov	dx,[fb_desc + 8]
		cmp	dx,000ah
		jae	.cpu
		add	dx,000ah
.cpu:		shr	ax,4
		shl	dx,12
		or	ax,dx
		mov	[g0_seg],ax
		cli
		mov	dx,0124h		; screen 0: no transparent colour
		xor	ax,ax
		out	dx,ax
		mov	dx,0126h		; screen 1: colour 0 transparent
		mov	ax,0001h
		out	dx,ax
		mov	dx,0153h		; GVRAM, single plane
		mov	al,54h
		out	dx,al
		mov	dx,0580h
		mov	al,10h
		out	dx,al
		sti
		clc
		ret
.fail:		stc
		ret

fail:		mov	si,s_fail
		call	puts
		call	wait_key
		jmp	0ffffh:0000h

; ---------------------------------------------------------------------------
; Rulers

draw:		mov	es,[g0_seg]		; clear both screens, 240 lines
		xor	di,di
		xor	ax,ax
		mov	cx,RULER_LINES * LINE_BYTES / 2
		rep	stosw
		mov	bx,G1_SEG
		mov	es,bx
		xor	di,di
		mov	cx,RULER_LINES * LINE_BYTES / 2
		rep	stosw
		mov	es,[g0_seg]		; screen 0: bytes 0-79, colours 1-7
		xor	bx,bx
		mov	byte [colour_base],1
		call	ruler
		mov	bx,G1_SEG		; screen 1: bytes 80-159, colours 9-15
		mov	es,bx
		mov	bx,80
		mov	byte [colour_base],9
		call	ruler
		mov	cl,[test_no]		; test number: white blocks on screen 1
		xor	ch,ch
		mov	di,2 * LINE_BYTES + 150
.blk:		mov	byte [es:di],0ffh
		mov	byte [es:di + LINE_BYTES],0ffh
		mov	byte [es:di + 2 * LINE_BYTES],0ffh
		sub	di,2
		loop	.blk
		push	cs
		pop	es
		ret

; 8-line bands at bytes BX to BX + 79 of ES, numbered.
ruler:		xor	si,si			; SI: band
.band:		mov	ax,si			; colour: base + band mod 7
		mov	dl,7
		div	dl
		mov	byte [ink],0ffh		; white digits on dark bands,
		cmp	ah,3			; black on green, cyan, yellow, white
		jb	.dark
		mov	byte [ink],00h
.dark:		mov	al,ah
		add	al,[colour_base]
		mov	ah,al
		shl	ah,4
		or	al,ah
		imul	di,si,8 * LINE_BYTES
		add	di,bx
		mov	dx,8
.row:		mov	cx,80
		rep	stosb
		add	di,LINE_BYTES - 80
		dec	dx
		jnz	.row
		imul	di,si,8 * LINE_BYTES	; the number, on line 1
		add	di,LINE_BYTES + 2
		add	di,bx
		imul	ax,si,8
		call	number
		inc	si
		cmp	si,RULER_LINES / 8
		jb	.band
		ret

; Decimal AX (0-999) at ES:DI, 3x5 digits two dots a pixel.
number:		push	bx
		push	si
		mov	bl,100
		div	bl			; AL hundreds, AH rest
		mov	[digits],al
		mov	al,ah
		xor	ah,ah
		mov	bl,10
		div	bl
		mov	[digits + 1],al
		mov	[digits + 2],ah
		xor	bx,bx
.d:		mov	al,[digits + bx]
		or	bx,bx			; no leading zero
		jnz	.draw
		or	al,al
		jz	.skip
.draw:		call	digit
.skip:		add	di,4
		inc	bx
		cmp	bx,3
		jb	.d
		pop	si
		pop	bx
		ret

; Digit AL at ES:DI (keeps DI).
digit:		push	di
		push	bx
		xor	ah,ah
		imul	si,ax,5
		add	si,font
		mov	dx,5
.row:		lodsb
		mov	cx,3
		push	di
.px:		test	al,4
		jz	.nx
		mov	ah,[ink]
		mov	[es:di],ah
.nx:		inc	di
		shl	al,1
		loop	.px
		pop	di
		add	di,LINE_BYTES
		dec	dx
		jnz	.row
		pop	bx
		pop	di
		ret

; ---------------------------------------------------------------------------

tsp_cmd:	mov	ah,al
		mov	dx,0142h
.w:		in	al,dx
		test	al,05h
		jnz	.w
		mov	al,ah
		out	dx,al
		ret

tsp_prm:	mov	ah,al
		mov	dx,0142h
.w:		in	al,dx
		test	al,01h
		jnz	.w
		mov	al,ah
		mov	dx,0146h
		out	dx,al
		ret

putc:		pusha
		push	ds
		push	es
		xor	ah,ah
		mov	dx,ax
		int	83h
		pop	es
		pop	ds
		popa
		ret

puts:		push	ax
.l:		mov	al,[cs:si]
		inc	si
		or	al,al
		jz	.r
		call	putc
		jmp	.l
.r:		pop	ax
		ret

crlf:		push	si
		mov	si,s_crlf
		call	puts
		pop	si
		ret

puthex16:	push	ax
		mov	al,ah
		call	puthex8
		pop	ax
puthex8:	push	ax
		shr	al,4
		call	.digit
		pop	ax
		and	al,0fh
.digit:		push	ax
		add	al,'0'
		cmp	al,'9'
		jbe	.out
		add	al,7
.out:		call	putc
		pop	ax
		ret

wait_key:	mov	ah,0ch
		int	82h
		mov	ah,09h
		int	82h
		ret

; ---------------------------------------------------------------------------

s_menu		db	'FB1TEST: lines shown by graphics screen 1, 320x224', 13, 10, 13, 10
		db	'1  register readback (text)', 13, 10
		db	'2  FBL = DSH = 224 (as M04 first version)', 13, 10
		db	'3  2 + FB1 FBW 160, DSP 0', 13, 10
		db	'4  2 + GRMODE 204 lines', 13, 10
		db	'5  2 + FB1 DSH 240', 13, 10
		db	'6  2, writes after SYNC', 13, 10
		db	'7  2 + GRMODE 400 lines', 13, 10, 13, 10
		db	'Tests 2-7: 15 kHz monitor; left half screen 0, right half', 13, 10
		db	'screen 1; any key reboots.', 13, 10, 0
s_before	db	13, 10, 'After the BIOS set-up: 0100 0102 / FB0 / FB1', 13, 10, 0
s_after		db	'After the writes of test 2:', 13, 10, 0
s_key		db	13, 10, 'Any key reboots.', 13, 10, 0
s_fail		db	13, 10, 'Graphics BIOS call failed. Any key reboots.', 13, 10, 0
s_crlf		db	13, 10, 0

; SYNC: 15.98 kHz, TBL 37, 224 active lines, bottom 2, sync 4
sync224		db	0c1h, 57h, 1ch, 00h, 9fh, 00h, 10h, 0fh, 25h, 00h, 0e0h, 00h, 02h, 04h

; 3x5 digits, bit 2 the left pixel
font		db	7, 5, 5, 5, 7		; 0
		db	2, 6, 2, 2, 7		; 1
		db	7, 1, 7, 4, 7		; 2
		db	7, 1, 3, 1, 7		; 3
		db	5, 5, 7, 1, 1		; 4
		db	7, 4, 7, 1, 7		; 5
		db	7, 4, 7, 5, 7		; 6
		db	7, 1, 1, 2, 2		; 7
		db	7, 5, 7, 5, 7		; 8
		db	7, 5, 7, 1, 7		; 9

		align	2
fb_desc		dw	4, 320, LINES, 0, 0, 0
g0_seg		dw	0
test_no		db	0
colour_base	db	0
digits		db	0, 0, 0
ink		db	0
		align	2
regs_before	times 34 dw 0
regs_after	times 34 dw 0

		times	4000h - ($ - $$) db 0
