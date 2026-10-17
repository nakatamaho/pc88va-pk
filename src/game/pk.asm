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
; PK: The Game PK for the PC-88VA (docs/DESIGN.md).
;
; Loaded by src/boot/ipl.asm to 2000:0000 with the data the builder
; (tools/build.py) places after the code: the patched Z80 program at
; 2000:4000 and the graphics data from 2000:8000.
;
; The arcade program runs in the uPD9002's Z80-compatible mode in the
; segment Z80SEG. Native code runs only in the VRTC interrupt (IR2, INT 0Ah):
; it does the frame's native work and then injects the Z80's mode 1
; interrupt by pushing the Z80 PC on the Z80 stack (DS0:BP), setting the
; saved IP to 0038h and clearing IE in the saved PSW. M01 established this
; on vaeg, the PC-88VA and the PC-88VA2.
;
; Screen: graphics screen 0 only. GVRAM holds four 320x240 areas: the
; background (tiles only, not shown) and three display pages. Each frame
; one page is brought up to date from the background, the sprites are
; drawn into it, and it is shown at the next VRTC by FB0's display start
; address (DSA). Three pages, so that the page being drawn is neither the
; one just selected nor the one selected a frame earlier, which on the
; PC-88VA2 is still being scanned at the bottom of the picture after the
; VRTC (M05). DSA also carries the picture position chosen on the
; alignment screen.
;
; Sound (M06, M07): the program's WSG registers (5040h-505Fh) are
; played every frame on the YM2203's three FM channels with voices fitted
; to the WSG waveforms, or on its SSG square waves (F10 screen; SOUND_SSG
; makes SSG the default; NO_FM, used for the MS-DOS build, leaves out FM
; and its ROM-derived voices).
;
; Input (M05): the key matrix is read every frame into the program's IN0
; and IN1. F10 opens the DIP switch screen (the game is paused); ESC
; restarts the machine.

		cpu	186
		org	0

; Segments. The self-booting disk loads the code to 2000h; PK.COM
; (src/dos/pk.asm) loads it to LOAD_SEG, with the other segments
; packed after it: LOAD_SEG + 1000h Z80, + 2000h render tables (to E800h),
; + 2C00h menu (4000h-47FFh), ending at LOAD_SEG + 3080h.
%ifdef LOAD_SEG
Z80SEG		equ	LOAD_SEG + 1000h
%else
Z80SEG		equ	5000h		; the 64 KiB compatible-mode space
%endif
ROM_OFFSET	equ	4000h		; patched program in this segment
ROM_BYTES	equ	4000h
BRKEM_VEC	equ	70h		; 40h-7Bh unused (technical manual, vector map)
VRTC_VEC	equ	0ah
ICU0		equ	188h
ICU1		equ	18ah

IN0		equ	5100h		; Z80 addresses of the redirected inputs
IN1		equ	5140h		; (tools/patches.py)
DSW		equ	5180h
DSW_DEFAULT	equ	0c9h		; 1 coin 1 credit, 3 lives, 10000, normal

LINES		equ	224
LINE_BYTES	equ	160		; 320 dots, 4 bits per pixel

; GVRAM areas, in paragraphs from the start of screen 0. Each area is 240
; lines: 8 blank lines, the 224-line picture, 8 blank lines, so that the
; picture can be moved by DSA without showing another area.
AREA_PARAS	equ	0960h		; 240 lines
ORIGIN_PARAS	equ	0050h		; 8 lines: the picture's line 0
BG_AREA		equ	0
PAGE0_AREA	equ	1
PAGES		equ	3
AREAS		equ	1 + PAGES
FB_LINES	equ	AREAS * 240	; FB0 FBL: all areas, no wrap
DUMP_PARAS	equ	AREAS * AREA_PARAS	; DEBUG_DUMP: tile and colour RAM

; Payload from tools/build.py (offsets in this segment)
TILE_ROWS	equ	8000h		; 256 tiles x 8 rows x 2 bytes, 2 bits/pixel
LOOKUP		equ	9000h		; 32 palettes x 4 colour indexes
PALETTE		equ	9080h		; 16 PC-88VA palette words
SCREEN_OFFS	equ	9100h		; picture offset of each tile RAM byte
FM_VOICES	equ	9900h		; 8 waves x (LOW, HIGH) x 9 bytes
PROGRAM_KIND	equ	9f00h		; 0: version A (IM 1), 1: version B (IM 2)
SPRITE_ROWS	equ	0a000h		; 64 codes x 2 flips x 16 rows x 9 bytes
SPRITE_ROWS_BYTES equ	4800h
SPRITE_ROW	equ	9		; 4 bytes even-aligned, 5 odd-aligned
SPRITE_VARIANT	equ	16 * SPRITE_ROW

; Render tables, built at start
%ifdef LOAD_SEG
DATASEG		equ	LOAD_SEG + 2000h
%else
DATASEG		equ	6000h
%endif
EXPAND		equ	0000h		; 32 palettes x 256: 4 pixels -> 2 bytes
SHADOW_TILE	equ	4000h		; tile RAM as last drawn
SHADOW_COLOUR	equ	4400h		; colour RAM as last drawn
D_SCREEN_OFFS	equ	4800h		; copy of SCREEN_OFFS
D_TILE_ROWS	equ	5000h		; copy of TILE_ROWS
MASK		equ	6000h		; as EXPAND: 0Fh nibbles where transparent
D_SPRITE_ROWS	equ	0a000h		; copy of SPRITE_ROWS
TILE_RAM	equ	4000h		; Z80 addresses
COLOUR_RAM	equ	4400h
SPRITE_ATTR	equ	4ff0h		; 8 x (code << 2 | flip y << 1 | flip x, colour)
SPRITE_POS	equ	5060h		; 8 x (y, x), written by the program
MAX_WORDS	equ	16		; changed words drawn per frame (2 tiles each)
MAX_QUEUE	equ	2 * MAX_WORDS	; tiles to copy to the other page
MAX_RECTS	equ	16		; 8 sprites, each possibly wrapped
RECT		equ	6		; offset, column byte, rows, width bytes, pad

; DIP switch screen: a tile picture in the layout of tile and colour RAM,
; drawn with the game's renderer
%ifdef LOAD_SEG
MENUSEG		equ	LOAD_SEG + 2c00h
%else
MENUSEG		equ	7000h		; tiles at 4000h, colours at 4400h
%endif
PAL_TITLE	equ	1		; red     (colour PROM palettes whose
PAL_TEXT	equ	15		; white    colour 3, used by the font,
PAL_VALUE	equ	5		; cyan     has the colour named)
PAL_SELECT	equ	9		; yellow
MENU_ITEMS	equ	7		; 5 DIP switches, SOUND, TEST
DSW_ITEMS	equ	5
STUB_PC		equ	5200h		; Z80 address of the sound-test stub
IM2_STUB	equ	5280h		; Z80 address of the version B dispatch

; Keys (scan_keys)
K_UP		equ	0001h
K_DOWN		equ	0002h
K_LEFT		equ	0004h
K_RIGHT		equ	0008h
K_COIN		equ	0010h
K_START1	equ	0020h
K_START2	equ	0040h
K_ESC		equ	0080h
K_F10		equ	0100h
K_PLAY		equ	0200h		; RETURN or SPACE

; Alignment screen
%ifndef ALIGN_FRAMES
ALIGN_FRAMES	equ	300		; about 5 s, restarted by every key
%endif
ALIGN_WHITE	equ	0ffh		; colour 15 in both pixels of a byte
SHIFT_X_MAX	equ	16		; dots, in steps of 8 (DSA is in 4 bytes)
SHIFT_Y_MAX	equ	8		; lines

%macro BRKEM 1
		db	0fh, 0ffh, %1
%endmacro

start:		cli
		mov	ax,cs
		mov	ds,ax
		mov	es,ax
		mov	ss,ax
		mov	sp,0fffeh
		cld
		sti
		mov	dx,01cbh		; the machine must run at 15 kHz: port
		in	al,dx			; 1CBh bit 3 is 1 at 24.8 kHz (technical
		test	al,08h			; manual 4.9.2; DIP switch SW1 on)
		jz	.khz15
		mov	si,s_24khz
		jmp	message
.khz15:		call	screen_init
		jc	fail
		call	render_init
		cli
		call	vrtc_install
		sti
		call	align_screen
		call	sound_init
		call	z80_init
		cli
		mov	ax,Z80SEG		; enter the program at Z80 0000h
		mov	ds,ax
		xor	ax,ax
		xor	bx,bx
		xor	cx,cx
		xor	dx,dx
		xor	si,si
		xor	di,di
		xor	bp,bp
		BRKEM	BRKEM_VEC
		jmp	$			; not reached: no RETEM

fail:		mov	si,s_fail
; Show the text at SI and stop.
message:
.p:		lodsb
		or	al,al
		jz	.halt
		xor	ah,ah
		mov	dx,ax
		int	83h
		jmp	.p
.halt:		hlt
		jmp	.halt

; ---------------------------------------------------------------------------
; Screen: graphics screen 0, 320 dots, 4 bits per pixel, 15.98 kHz SYNC
; 37/224/2/4 (59.9 Hz); the sequence of M01 menu 3 (vaeg's V480PAT "224 R
; W"), with FB0's virtual height covering the three GVRAM areas. Leaves
; GVRAM mapped for CPU writes. CF = 1 on a BIOS error.

screen_init:	mov	ax,1702h		; clear the text screen
		int	83h
		mov	ah,00h			; graphics: single plane, 4 bits/pixel
		mov	bh,0a0h
		mov	bl,0ah			; 200-line rasters, 320 dots
		mov	cx,0404h
		xor	dx,dx
		int	8fh
		or	ax,ax
		jnz	.fail
		mov	di,fb_desc
		mov	ax,0100h		; frame buffer 0 of screen 0
		mov	cx,1
		int	8fh
		or	ax,ax
		jnz	.fail
		mov	di,fb_desc
		mov	ax,0700h		; its address, at fb_desc + 6
		mov	cl,0
		int	8fh
		or	ax,ax
		jnz	.fail
		push	cs
		pop	es
		mov	ax,[fb_desc + 6]	; linear address of screen 0
		mov	dx,[fb_desc + 8]
		cmp	dx,000ah
		jae	.cpu
		add	dx,000ah		; GVRAM-relative: GVRAM is at A0000h
.cpu:		mov	bx,ax			; segment of screen 0 (paragraph
		shr	bx,4			; aligned)
		mov	cx,dx
		shl	cx,12
		or	bx,cx
		mov	[gvram_seg],bx
		mov	cx,ORIGIN_PARAS		; the areas' picture origins
		add	bx,cx
		mov	[bg_seg],bx
		sub	dx,000ah		; GVRAM offset of the page origins
		add	ax,(PAGE0_AREA * AREA_PARAS + ORIGIN_PARAS) * 16
		adc	dx,0
		xor	si,si
.pages:		add	bx,AREA_PARAS
		mov	[page_seg + si],bx
		push	si
		shl	si,1
		mov	[page_dsa + si],ax
		mov	[page_dsa + si + 2],dx
		pop	si
		add	ax,AREA_PARAS * 16
		adc	dx,0
		add	si,2
		cmp	si,PAGES * 2
		jb	.pages
		cli
		mov	dx,0153h		; system memory area: GVRAM
		in	al,dx
		and	al,0f0h
		or	al,04h
		out	dx,al
		mov	dx,0580h		; single-plane write mode: CPU data
		mov	al,10h
		out	dx,al
		mov	bx,[gvram_seg]		; clear the three areas
		mov	dx,AREAS * AREA_PARAS
.clear:		mov	es,bx
		xor	di,di
		mov	cx,dx			; at most 4 KiB paragraphs = 64 KiB
		cmp	cx,1000h
		jbe	.n
		mov	cx,1000h
.n:		sub	dx,cx
		add	bx,cx
		shl	cx,3			; paragraphs -> words
		xor	ax,ax
		rep	stosw
		or	dx,dx
		jnz	.clear
		push	cs
		pop	es
		sti
		mov	ax,0b01h		; graphics display on
		int	8fh
		mov	ah,16h			; as V480PAT before changing the timing
		int	84h
		mov	ax,0500h		; frame-buffer display set-up (V480PAT)
		mov	cl,00h
		xor	bx,bx
		xor	dx,dx
		int	8fh
		mov	ax,0b01h
		int	8fh
		cli
		xor	ax,ax
		mov	dx,010ah
		out	dx,ax
		mov	ax,FB_LINES		; FB0 FBL: the three areas
		mov	dx,0206h
		out	dx,ax
		mov	ax,LINES		; FB0 DSH
		mov	dx,0212h
		out	dx,ax
		mov	byte [back],0
		call	show_page		; page 0, blank
		mov	si,sync224		; TSP SYNC
		mov	al,10h
		call	tsp_cmd
		mov	cx,14
.prm:		lodsb
		call	tsp_prm
		loop	.prm
		sti
		clc
		ret
.fail:		stc
		ret

; FB0 DSA = page [back] moved by shift_x dots and shift_y lines. Word
; writes only (byte writes to a DSA can hang the hardware,
; demos/sgp-pseudo-sprite).
show_page:	push	bx
		mov	bl,[cs:back]
		xor	bh,bh
		shl	bx,2
		mov	ax,[cs:shift_y]		; picture down: DSA - lines * 160
		imul	ax,ax,LINE_BYTES
		mov	dx,[cs:shift_x]		; picture right: DSA - dots / 2
		sar	dx,1
		add	ax,dx
		cwd
		neg	ax			; DX:AX = -(that), 32 bits
		adc	dx,0
		neg	dx
		add	ax,[cs:page_dsa + bx]
		adc	dx,[cs:page_dsa + bx + 2]
		push	dx
		mov	dx,020eh
		out	dx,ax
		pop	ax
		mov	dx,0210h
		out	dx,ax
		pop	bx
		ret

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

; ---------------------------------------------------------------------------
; Alignment screen, before the game, on page 0: a white outline of the
; 288x224 game picture (dots 16-303) with ticks on its left edge every 8
; lines (longer every 32) and, while the picture is not moved sideways, a
; white outline of the whole 320x224 raster for the monitor's automatic
; adjustment. (Moved sideways, DSA shows the neighbouring line's dots at the
; edges, so the raster outline would appear at the wrong side.) The picture
; is moved with the numeric keypad or the cursor keys, in the game's
; orientation (monitor turned clockwise): 8 up and 2 down by 8 dots of the
; raster width (at most 16), 4 left and 6 right by one line (at most 8).
; It ends after ALIGN_FRAMES frames without a key, or with RETURN or SPACE.
; The keys are read from the key matrix (ports 00h-0Eh).

align_screen:	mov	byte [back],0
		call	align_draw
		mov	word [align_left],ALIGN_FRAMES
		call	read_keys
		mov	[keys_prev],al
.frame:		mov	ax,[ticks]		; wait for a VRTC
.wait:		cmp	ax,[ticks]
		je	.wait
		call	read_keys
		mov	ah,[keys_prev]
		mov	[keys_prev],al
		not	ah
		and	al,ah			; AL: keys just pressed
		test	al,10h
		jnz	.done
		test	al,0fh
		jz	.count
		mov	word [align_left],ALIGN_FRAMES
		test	al,01h			; game up: raster left
		jz	.k2
		cmp	word [shift_x],-SHIFT_X_MAX
		jle	.k2
		sub	word [shift_x],8
.k2:		test	al,02h			; game down: raster right
		jz	.k4
		cmp	word [shift_x],SHIFT_X_MAX
		jge	.k4
		add	word [shift_x],8
.k4:		test	al,04h			; game left: raster down
		jz	.k6
		cmp	word [shift_y],SHIFT_Y_MAX
		jge	.k6
		inc	word [shift_y]
.k6:		test	al,08h			; game right: raster up
		jz	.show
		cmp	word [shift_y],-SHIFT_Y_MAX
		jle	.show
		dec	word [shift_y]
.show:		call	align_draw
		jmp	.frame
.count:		dec	word [align_left]
		jnz	.frame
.done:		call	page0_clear
		ret

; Draw the outlines for the current position on page 0 and show it.
align_draw:	call	page0_clear
		mov	es,[page_seg]
		mov	bx,8			; the game picture: bytes 8-151
		mov	dx,151
		call	outline
		cmp	word [shift_x],0
		jne	.show
		xor	bx,bx			; the raster: bytes 0-159
		mov	dx,LINE_BYTES - 1
		call	outline
.show:		push	cs
		pop	es
		cli
		call	show_page
		sti
		ret

page0_clear:	mov	es,[page_seg]
		xor	di,di
		xor	ax,ax
		mov	cx,LINES * LINE_BYTES / 2
		rep	stosw
		push	cs
		pop	es
		ret

; Outline of bytes BX to DX of lines 0-223 in ES, ticks inside the left
; edge every 8 lines (longer every 32).
outline:	mov	cx,dx			; lines 0 and 223
		sub	cx,bx
		inc	cx
		push	cx
		mov	di,bx
		mov	al,ALIGN_WHITE
		rep	stosb
		pop	cx
		mov	di,(LINES - 1) * LINE_BYTES
		add	di,bx
		rep	stosb
		xor	si,si			; SI: line
.line:		imul	di,si,LINE_BYTES	; (MUL would change DX)
		add	di,bx
		push	di
		add	di,dx
		sub	di,bx
		mov	byte [es:di],ALIGN_WHITE
		pop	di
		mov	byte [es:di],ALIGN_WHITE
		inc	di
		mov	cx,3			; tick: 6 dots
		test	si,1fh
		jnz	.short
		mov	cx,7			; long tick: 14 dots
.short:		test	si,07h
		jnz	.next
		mov	al,ALIGN_WHITE
		rep	stosb
.next:		inc	si
		cmp	si,LINES
		jb	.line
		ret

; AL = keys held: bit 0 game up (keypad 8, cursor up), 1 down (2, cursor
; down), 2 left (4, cursor left), 3 right (6, cursor right), 4 RETURN or
; SPACE. The matrix is active low; the layout is the PC-8801's.
read_keys:	push	bx
		push	dx
		xor	bl,bl
		in	al,00h			; keypad 0-7
		not	al
		test	al,04h
		jz	.r4
		or	bl,02h
.r4:		test	al,10h
		jz	.r6
		or	bl,04h
.r6:		test	al,40h
		jz	.r8
		or	bl,08h
.r8:		in	al,01h			; keypad 8, 9, ..., RETURN (bit 7)
		not	al
		test	al,01h
		jz	.rret
		or	bl,01h
.rret:		test	al,80h
		jz	.cur1
		or	bl,10h
.cur1:		in	al,08h			; CLR, UP (bit 1), RIGHT (bit 2), ...
		not	al
		test	al,02h
		jz	.cur2
		or	bl,01h
.cur2:		test	al,04h
		jz	.cur3
		or	bl,08h
.cur3:		in	al,0ah			; TAB, DOWN (bit 1), LEFT (bit 2), ...
		not	al
		test	al,02h
		jz	.cur4
		or	bl,02h
.cur4:		test	al,04h
		jz	.space
		or	bl,04h
.space:		in	al,09h			; STOP, F1-F5, SPACE (bit 6), ESC
		not	al
		test	al,40h
		jz	.ret
		or	bl,10h
.ret:		in	al,0eh			; RETURN (bits 0-1)
		not	al
		test	al,03h
		jz	.done
		or	bl,10h
.done:		mov	al,bl
		pop	dx
		pop	bx
		ret

; ---------------------------------------------------------------------------
; The compatible-mode space: the patched program at 0000h, zero above it,
; idle inputs; BRKEM_VEC -> Z80SEG:0000.

z80_init:	mov	ax,Z80SEG
		mov	es,ax
		xor	di,di
		mov	si,ROM_OFFSET
		mov	cx,ROM_BYTES / 2
		rep	movsw
		xor	ax,ax
		mov	cx,(10000h - ROM_BYTES) / 2
		rep	stosw
		mov	byte [es:IN0],0ffh
		mov	byte [es:IN1],0ffh
		mov	byte [es:DSW],DSW_DEFAULT
		mov	si,z80_stub
		mov	di,STUB_PC
		mov	cx,z80_stub_end - z80_stub
		rep	movsb
		cmp	byte [PROGRAM_KIND],0	; version B: interrupts through
		je	.kind			; im2_stub
		mov	si,im2_stub
		mov	di,IM2_STUB
		mov	cx,im2_stub_end - im2_stub
		rep	movsb
		mov	word [isr_entry],IM2_STUB
.kind:		xor	ax,ax
		mov	es,ax
		mov	word [es:BRKEM_VEC * 4],0000h
		mov	word [es:BRKEM_VEC * 4 + 2],Z80SEG
		push	cs
		pop	es
		ret

; ---------------------------------------------------------------------------
; Background rendering. Tile RAM and colour RAM are compared with the copies
; last drawn; each changed tile is drawn from its 2-bit rows through its
; palette's expansion table (4 pixels -> 2 bytes of 4-bit colour indexes,
; the left pixel in the high nibble) into the background area and copied to
; the page being drawn; the other page gets it in the next frame. At most
; MAX_WORDS changed words a frame; the rest stay different and are drawn in
; the next frames.

render_init:	push	es
		mov	ax,DATASEG
		mov	es,ax
		xor	di,di			; EXPAND
		mov	si,LOOKUP
		mov	dl,32			; palettes
.pal:		xor	cx,cx			; CX: 4 pixels, 2 bits each
.byte:		mov	bl,cl
		shr	bl,6
		xor	bh,bh
		mov	al,[si + bx]
		shl	al,4
		mov	bl,cl
		shr	bl,4
		and	bl,3
		or	al,[si + bx]
		mov	ah,al
		mov	bl,cl
		shr	bl,2
		and	bl,3
		mov	al,[si + bx]
		shl	al,4
		mov	bl,cl
		and	bl,3
		or	al,[si + bx]
		xchg	al,ah			; AL: pixels 0-1, AH: pixels 2-3
		stosw
		call	mask_entry		; the same entry of MASK
		mov	[es:di - 2 + MASK],ax
		inc	cx
		cmp	cx,256
		jb	.byte
		add	si,4
		dec	dl
		jnz	.pal
		xor	ax,ax			; shadows: Z80 RAM starts at zero
		mov	cx,800h / 2
		rep	stosw
		mov	si,SCREEN_OFFS		; DI = D_SCREEN_OFFS
		mov	cx,800h / 2
		rep	movsw
		mov	si,TILE_ROWS		; DI = D_TILE_ROWS
		mov	cx,1000h / 2
		rep	movsw
		mov	si,SPRITE_ROWS
		mov	di,D_SPRITE_ROWS
		mov	cx,SPRITE_ROWS_BYTES / 2
		rep	movsw
		pop	es
		mov	si,PALETTE		; palette set 0
		mov	dx,0300h
		mov	cx,16
.colour:	lodsw
		out	dx,ax
		add	dx,2
		loop	.colour
		ret

; MASK entry for the 4 pixels CL of the palette at SI: a 0Fh nibble for each
; pixel whose colour index is 0. Returns AX; keeps the other registers.
mask_entry:	push	bx
		push	dx
		xor	dx,dx			; DX: 4 nibbles, built from pixel 0
		mov	ah,6			; shift of pixel 0's bits in CL
.px:		mov	bl,cl
		push	cx
		mov	cl,ah
		shr	bl,cl
		pop	cx
		and	bl,3
		xor	bh,bh
		shl	dx,4
		cmp	byte [si + bx],0
		jne	.opaque
		or	dl,0fh
.opaque:	sub	ah,2
		jns	.px
		mov	ax,dx			; nibbles p0 p1 p2 p3 -> AL = p0p1,
		xchg	al,ah			; AH = p2p3
		pop	dx
		pop	bx
		ret

; Copy the tiles drawn into the background in the previous two frames to
; the page being drawn. Each page has the queue of the tiles drawn in the
; frame that drew it; the page's own queue is three frames old and has
; reached both other pages, so it is emptied for this frame.
apply_queue:	mov	al,[cs:back]
		xor	ah,ah
		mov	bx,ax
		shl	bx,1
		mov	word [cs:queue_count + bx],0
		mov	ds,[cs:bg_seg]
		mov	es,[cs:draw_seg]
		inc	ax
		call	.one
		inc	ax
.one:		cmp	ax,PAGES		; AX: page, modulo PAGES
		jb	.idx
		sub	ax,PAGES
.idx:		push	ax
		mov	bx,ax
		shl	bx,1
		mov	cx,[cs:queue_count + bx]
		jcxz	.done
		imul	bx,ax,MAX_QUEUE * 2
		add	bx,queue
.tile:		mov	di,[cs:bx]
		call	copy_cell
		add	bx,2
		loop	.tile
.done:		pop	ax
		ret

; Copy the 8x8 cell at offset DI from DS to ES. Keeps BX, CX, DI.
copy_cell:	push	cx
		push	di
		mov	dx,8
.row:		mov	si,di
		movsw
		movsw
		add	di,LINE_BYTES - 4
		dec	dx
		jnz	.row
		pop	di
		pop	cx
		ret

; Draw what changed (DS, ES and all registers are free).
render:		mov	ax,DATASEG
		mov	es,ax
		mov	ds,[cs:src_seg]
		mov	ax,[cs:render_words]
		mov	[cs:budget],ax
		mov	si,TILE_RAM
		mov	di,SHADOW_TILE
		mov	cx,400h / 2
		call	.scan
		mov	si,COLOUR_RAM
		mov	di,SHADOW_COLOUR
		mov	cx,400h / 2
.scan:		cmp	word [cs:budget],0
		je	.done
		jcxz	.done
		repe	cmpsw
		je	.done			; the last word compared equal
		push	cx
		push	si
		push	di
		lea	bx,[si - 2]
		and	bx,03ffh
		call	draw_tile
		inc	bx
		call	draw_tile
		pop	di
		pop	si
		pop	cx
		dec	word [cs:budget]
		jmp	.scan
.done:		ret

; Draw the tile at tile RAM offset BX (DS = the source, ES = DATASEG) into the
; background, copy it to the page being drawn, queue it for the other page
; and record it as drawn. Keeps BX, DS and ES.
draw_tile:	mov	al,[TILE_RAM + bx]
		mov	ah,[COLOUR_RAM + bx]
		mov	[es:SHADOW_TILE + bx],al
		mov	[es:SHADOW_COLOUR + bx],ah
		push	bx
		shl	bx,1
		mov	di,[es:D_SCREEN_OFFS + bx]
		cmp	di,0ffffh
		je	.hidden
		mov	dl,al			; SI: the tile's rows
		xor	dh,dh
		shl	dx,4
		add	dx,D_TILE_ROWS
		mov	si,dx
		mov	dl,ah			; BP: the palette's expansion table
		and	dx,1fh
		shl	dx,9
		mov	bp,dx
		push	ds
		push	es
		mov	ax,DATASEG
		mov	ds,ax
		mov	es,[cs:bg_seg]
		push	di
		mov	cx,8
.row:		lodsw				; AL: pixels 0-3, AH: pixels 4-7
		mov	bl,al
		xor	bh,bh
		shl	bx,1
		add	bx,bp
		mov	dx,[bx]
		mov	bl,ah
		xor	bh,bh
		shl	bx,1
		add	bx,bp
		mov	ax,[bx]
		xchg	ax,dx
		stosw
		mov	ax,dx
		stosw
		add	di,LINE_BYTES - 4
		loop	.row
		pop	di
		mov	ds,[cs:bg_seg]		; to the page being drawn
		mov	es,[cs:draw_seg]
		call	copy_cell
		mov	al,[cs:back]		; and later to the other pages
		xor	ah,ah
		mov	bx,ax
		shl	bx,1
		mov	cx,[cs:queue_count + bx]
		cmp	cx,MAX_QUEUE
		jae	.queued
		inc	word [cs:queue_count + bx]
		imul	bx,ax,MAX_QUEUE * 2
		shl	cx,1
		add	bx,cx
		mov	[cs:queue + bx],di
.queued:	pop	es
		pop	ds
.hidden:	pop	bx
		ret

; ---------------------------------------------------------------------------
; Sprites, drawn into the page being drawn. MAME's screen update for the board
; gives the placement: sprite i has its code and flips at SPRITE_ATTR + 2i,
; its palette at + 2i + 1, Y at SPRITE_POS + 2i and X at + 2i + 1; on the
; board's raster sx = 272 - X and sy = Y - 31, sprites 0-2 one line lower
; (sy + 1), sprite 0 in front; a sprite at sx >= 257 is also drawn at
; sx - 256; only raster columns 16-271 show sprites. The raster is at dot 16
; of the picture.

; Read the eight sprites' registers (before the tiles are drawn, so that the
; erase below sees the same frame).
sprite_regs:	mov	ax,Z80SEG
		mov	ds,ax
		xor	si,si			; SI: 2 x sprite number
		xor	di,di			; DI: sprite number
.read:		mov	al,[SPRITE_ATTR + si]
		mov	[cs:s_attr + di],al
		mov	al,[SPRITE_ATTR + 1 + si]
		mov	[cs:s_colour + di],al
		mov	al,[SPRITE_POS + 1 + si]
		xor	ah,ah
		mov	dx,272
		sub	dx,ax
		mov	[cs:s_x + si],dx
		mov	al,[SPRITE_POS + si]
		xor	ah,ah
		sub	ax,31
		cmp	di,2
		ja	.y
		inc	ax
.y:		mov	[cs:s_y + si],ax
		add	si,2
		inc	di
		cmp	di,8
		jb	.read
		ret

; BP = the rectangle list of the page being drawn.
rect_list:	mov	bl,[cs:back]
		xor	bh,bh
		mov	ax,2 + MAX_RECTS * RECT
		mul	bx
		add	ax,rects
		mov	bp,ax
		ret

; Restore the page's sprite rectangles from the background and empty the
; list.
erase_sprites:	call	rect_list
		mov	cx,[cs:bp]
		jcxz	.done
		mov	ds,[cs:bg_seg]
		mov	es,[cs:draw_seg]
		lea	si,[bp + 2]
.rect:		push	cx
		mov	di,[cs:si]
		mov	al,[cs:si + 4]		; width in bytes
		xor	ah,ah
		call	restore_part
		add	si,RECT
		pop	cx
		loop	.rect
.done:		mov	word [cs:bp],0
		ret

sprites:	call	rect_list
		mov	ax,DATASEG
		mov	ds,ax
		mov	es,[cs:draw_seg]
		mov	cx,7			; sprite 7 first, sprite 0 last
.sprite:	push	cx
		mov	bx,cx
		mov	al,[cs:s_attr + bx]
		mov	[cs:d_attr],al
		mov	al,[cs:s_colour + bx]
		mov	[cs:d_colour],al
		shl	bx,1
		mov	ax,[cs:s_y + bx]
		mov	[cs:d_y],ax
		mov	ax,[cs:s_x + bx]
		mov	[cs:d_x],ax
		call	draw_sprite
		cmp	word [cs:d_x],257
		jl	.next
		sub	word [cs:d_x],256	; wrapped copy
		call	draw_sprite
.next:		pop	cx
		dec	cx
		jns	.sprite
		jmp	clip_rects

; Restore, from the background, the parts of the listed rectangles outside
; raster columns 16-271, that is outside bytes 16-143 of a line.
clip_rects:	mov	cx,[cs:bp]
		jcxz	.done
		mov	ds,[cs:bg_seg]
		lea	si,[bp + 2]
.rect:		push	cx
		xor	bh,bh
		mov	bl,[cs:si + 2]		; column byte
		mov	dl,[cs:si + 4]		; width
		xor	dh,dh
		cmp	bx,16
		jae	.right
		mov	ax,16			; left part: columns BX..15
		sub	ax,bx
		cmp	ax,dx
		jbe	.l
		mov	ax,dx
.l:		mov	di,[cs:si]
		call	restore_part
.right:		mov	ax,bx
		add	ax,dx			; AX: end column
		cmp	ax,144
		jbe	.next
		mov	di,[cs:si]
		mov	cx,144			; right part from max(BX, 144)
		cmp	bx,cx
		jae	.r
		sub	cx,bx
		add	di,cx
		sub	ax,144
		jmp	.part
.r:		mov	ax,dx
.part:		call	restore_part
.next:		add	si,RECT
		pop	cx
		loop	.rect
.done:		ret

; Copy AX bytes from DI on each row of the rectangle at CS:SI from DS (the
; background) to ES (the page). Keeps SI, BX, DX.
restore_part:	push	bx
		push	dx
		push	si
		mov	bl,[cs:si + 3]		; rows
		mov	dx,ax
.row:		mov	si,di
		mov	cx,dx
		rep	movsb
		sub	di,dx
		add	di,LINE_BYTES
		dec	bl
		jnz	.row
		pop	si
		pop	dx
		pop	bx
		ret

; Draw the sprite in d_attr, d_colour, d_x (raster column), d_y (raster
; line), clipped to lines 0-223, into ES (DS = DATASEG) and add its
; rectangle to the list at BP.
draw_sprite:	mov	ax,[cs:d_y]
		cmp	ax,LINES
		jge	.ret
		cmp	ax,-15
		jl	.ret
		xor	cx,cx			; CX: first sprite row shown
		mov	dx,16			; DX: rows shown
		or	ax,ax
		jns	.top
		neg	ax
		mov	cx,ax
		sub	dx,ax
		xor	ax,ax
.top:		mov	bx,ax
		add	bx,dx
		cmp	bx,LINES
		jle	.bottom
		mov	dx,LINES
		sub	dx,ax
.bottom:	mov	[cs:d_rows],dx
		mov	[cs:d_first],cx
		mov	bx,LINE_BYTES		; DI: line AX, dot 16 + d_x
		mul	bx
		mov	di,ax
		mov	ax,[cs:d_x]
		add	ax,16
		mov	bx,ax
		shr	bx,1
		add	di,bx
		mov	[cs:d_column],bl
		and	ax,1			; odd dot: the 5-byte rows
		mov	[cs:d_odd],al
		mov	al,[cs:d_attr]		; BX: variant = code * 2 + flip x
		mov	bl,al
		shr	bl,2
		xor	bh,bh
		shl	bx,1
		test	al,1
		jz	.variant
		inc	bx
.variant:	mov	ax,SPRITE_VARIANT
		mul	bx
		add	ax,D_SPRITE_ROWS
		cmp	byte [cs:d_odd],0
		je	.even
		add	ax,4
.even:		mov	si,ax
		mov	ax,[cs:d_first]		; first source row, step
		mov	word [cs:d_step],SPRITE_ROW
		test	byte [cs:d_attr],2	; flip y: rows from the bottom
		jz	.down
		neg	ax
		add	ax,15
		mov	word [cs:d_step],-SPRITE_ROW
.down:		mov	bx,SPRITE_ROW
		mul	bx
		add	si,ax
		mov	dl,[cs:d_colour]	; DX: the palette's EXPAND table
		and	dx,1fh
		shl	dx,9
		mov	[cs:d_table],dx
		mov	cx,4			; groups of 4 pixels a row
		add	cl,[cs:d_odd]
		mov	[cs:d_groups],cx
		push	di
		mov	dx,[cs:d_rows]
.row:		push	si
		push	di
		mov	cx,[cs:d_groups]
.group:		mov	bl,[si]
		inc	si
		xor	bh,bh
		shl	bx,1
		add	bx,[cs:d_table]
		mov	ax,[es:di]
		and	ax,[bx + MASK]
		or	ax,[bx]
		stosw
		loop	.group
		pop	di
		pop	si
		add	di,LINE_BYTES
		add	si,[cs:d_step]
		dec	dx
		jnz	.row
		pop	di
		mov	bx,[cs:bp]		; record the rectangle
		cmp	bx,MAX_RECTS
		jae	.ret
		inc	word [cs:bp]
		mov	ax,RECT
		mul	bx
		mov	bx,ax
		add	bx,bp
		mov	[cs:bx + 2],di
		mov	al,[cs:d_column]
		mov	[cs:bx + 4],al
		mov	al,[cs:d_rows]
		mov	[cs:bx + 5],al
		mov	al,[cs:d_groups]
		shl	al,1
		mov	[cs:bx + 6],al
.ret:		ret

; ---------------------------------------------------------------------------
; Keys and the program's inputs

; AX = keys held (K_*), from the key matrix (PC-88VA layout, technical
; manual 2.2; active low). Moves: keypad 8 2 4 6 or the cursor keys, in the
; game's orientation. Coin: 5 (main or keypad). Start: 1, 2 (main).
scan_keys:	push	bx
		push	dx
		xor	bx,bx
		in	al,00h			; keypad 0-7
		not	al
		test	al,04h			; 2
		jz	.k4
		or	bx,K_DOWN
.k4:		test	al,10h			; 4
		jz	.k5
		or	bx,K_LEFT
.k5:		test	al,20h			; 5
		jz	.k6
		or	bx,K_COIN
.k6:		test	al,40h			; 6
		jz	.k8
		or	bx,K_RIGHT
.k8:		in	al,01h			; keypad 8 (bit 0)
		test	al,01h
		jnz	.main
		or	bx,K_UP
.main:		in	al,06h			; 0-7
		not	al
		test	al,02h			; 1
		jz	.m2
		or	bx,K_START1
.m2:		test	al,04h			; 2
		jz	.m5
		or	bx,K_START2
.m5:		test	al,20h			; 5
		jz	.c8
		or	bx,K_COIN
.c8:		in	al,08h			; up (bit 1), right (bit 2)
		not	al
		test	al,02h
		jz	.c8r
		or	bx,K_UP
.c8r:		test	al,04h
		jz	.ca
		or	bx,K_RIGHT
.ca:		in	al,0ah			; down (bit 1), left (bit 2)
		not	al
		test	al,02h
		jz	.car
		or	bx,K_DOWN
.car:		test	al,04h
		jz	.esc
		or	bx,K_LEFT
.esc:		in	al,09h			; ESC (bit 7)
		test	al,80h
		jnz	.f10
		or	bx,K_ESC
.f10:		in	al,0dh			; F10: port 0Dh bit 4 (technical
		and	al,10h			; manual), port 0Ch bit 4 (vaeg; F5
		jz	.f10on			; in the manual, unused here)
		in	al,0ch
		test	al,10h
		jnz	.done
.f10on:		or	bx,K_F10
.done:		in	al,01h			; RETURN (keypad, bit 7)
		test	al,80h
		jz	.play
		in	al,0eh			; RETURN (bits 0-1)
		and	al,03h
		cmp	al,03h
		jne	.play
		in	al,09h			; SPACE (bit 6)
		test	al,40h
		jnz	.keys
.play:		or	bx,K_PLAY
.keys:
%ifdef TEST_KEYS
		; vaeg tests: M = F10, D = down, R = right, U = up (typed through
		; the debug script's input-line)
		in	al,03h			; M: bit 5
		test	al,20h
		jnz	.td
		or	bx,K_F10
.td:		in	al,02h			; D: bit 4
		test	al,10h
		jnz	.tr
		or	bx,K_DOWN
.tr:		in	al,04h			; R: bit 2, U: bit 5
		test	al,04h
		jnz	.tu
		or	bx,K_RIGHT
.tu:		test	al,20h
		jnz	.tend
		or	bx,K_UP
.tend:
%endif
		mov	ax,bx
		pop	dx
		pop	bx
		ret

%ifdef KEY_DIAG
; Raw key matrix in the left margin of every page (dots 0-15): ports
; 00h-0Eh from the top, 8 lines a port (6 drawn), bit 7 on the left, each
; bit 2 dots wide: white = 0 (pressed), red = 1.
key_diag:	pusha
		push	es
		xor	si,si			; SI: page x 2
.page:		mov	es,[cs:page_seg + si]
		xor	dx,dx			; DX: port
		xor	di,di
.port:		in	al,dx
		mov	ah,al
		push	di
		mov	cx,8
.bit:		mov	al,11h
		shl	ah,1
		jc	.put
		mov	al,0ffh
.put:		mov	bx,6
		push	di
.col:		mov	[es:di],al
		add	di,LINE_BYTES
		dec	bx
		jnz	.col
		pop	di
		inc	di
		loop	.bit
		pop	di
		add	di,8 * LINE_BYTES
		inc	dx
		cmp	dx,0fh
		jb	.port
		add	si,2
		cmp	si,PAGES * 2
		jb	.page
		pop	es
		popa
		ret
%endif

; IN0 and IN1 (active low) from keys_held: IN0 bit 0 up, 1 left, 2 right,
; 3 down, 5 coin 1; IN1 bit 5 start 1, 6 start 2; the rest released
; (IN1 bit 4 test switch off, bit 7 upright cabinet).
inputs:		mov	ax,[cs:keys_held]
		mov	dl,0ffh			; IN0
		test	al,K_UP
		jz	.l
		and	dl,0feh
.l:		test	al,K_LEFT
		jz	.r
		and	dl,0fdh
.r:		test	al,K_RIGHT
		jz	.d
		and	dl,0fbh
.d:		test	al,K_DOWN
		jz	.c
		and	dl,0f7h
.c:		test	al,K_COIN
		jz	.in1
		and	dl,0dfh
.in1:		mov	dh,0ffh			; IN1
		test	al,K_START1
		jz	.s2
		and	dh,0dfh
.s2:		test	al,K_START2
		jz	.out
		and	dh,0bfh
.out:		push	ds
		mov	ax,Z80SEG
		mov	ds,ax
		mov	[IN0],dl
		mov	[IN1],dh
		pop	ds
		ret

; ---------------------------------------------------------------------------
; DIP switch screen (F10). The game is paused (no interrupt is injected).
; Keys 8 2 (cursor up, down) choose an item, 4 6 (left, right) change it,
; F10 returns. A changed DIP setting is written to the program's DSW and
; the program is restarted, as the board would be after a power cycle; the
; program reads the switches at its start. SOUND switches between FM and
; SSG at once. TEST plays one of the game's sounds (RETURN or SPACE plays
; it again): the program's own sound routines run from a small Z80 stub
; (z80_stub) injected instead of the interrupt routine, with the sound
; request bytes set by test_frame; the game itself stays paused. The
; request bytes are restored when the screen closes.

SOUND_REQS	equ	4e9ch		; effects 4E9Ch, 4EACh, 4EBCh; songs
					; 4ECCh, 4EDCh, 4EECh (16 apart)

menu_open:	mov	byte [cs:menu_on],1
		mov	byte [cs:menu_sel],0
		mov	byte [cs:test_on],0
		mov	byte [cs:test_sel],0
		push	ds
		mov	ax,Z80SEG
		mov	ds,ax
		mov	al,[DSW]
		mov	[cs:menu_dsw],al
		mov	[cs:menu_old],al
		xor	bx,bx			; save the sound requests
.save:		mov	al,[SOUND_REQS + bx]
		push	bx
		shr	bx,4
		mov	[cs:saved_reqs + bx],al
		pop	bx
		add	bx,10h
		cmp	bx,60h
		jb	.save
		pop	ds
		call	menu_build
		mov	ax,MENUSEG
		jmp	render_all

menu_frame:	call	test_frame
		mov	ax,[cs:keys_new]
		test	ax,K_F10
		jnz	.close
		mov	bl,[cs:menu_sel]
		test	ax,K_UP
		jz	.down
		dec	bl
		jns	.down
		mov	bl,MENU_ITEMS - 1
.down:		test	ax,K_DOWN
		jz	.sel
		inc	bl
		cmp	bl,MENU_ITEMS
		jb	.sel
		xor	bl,bl
.sel:		mov	[cs:menu_sel],bl
		cmp	bl,DSW_ITEMS
		jb	.dsw
		cmp	bl,DSW_ITEMS
		jne	.test
		test	ax,K_LEFT | K_RIGHT	; SOUND
		jz	.redraw
		call	sound_toggle
		jmp	.redraw
.test:		test	ax,K_PLAY		; TEST
		jz	.tchange
		mov	byte [cs:test_on],1	; restart the selected sound
		mov	byte [cs:test_phase],0
.tchange:	test	ax,K_LEFT | K_RIGHT
		jz	.redraw
		mov	dl,[cs:test_sel]
		test	ax,K_RIGHT
		jz	.tleft
		inc	dl
		cmp	dl,TESTS
		jb	.tset
		xor	dl,dl
		jmp	.tset
.tleft:		dec	dl
		jns	.tset
		mov	dl,TESTS - 1
.tset:		mov	[cs:test_sel],dl
		mov	byte [cs:test_on],1
		mov	byte [cs:test_phase],0
		jmp	.redraw
.dsw:		xor	bh,bh			; BX: the item's table entry
		imul	bx,bx,ITEM
		add	bx,items
		test	ax,K_LEFT | K_RIGHT
		jz	.redraw
		mov	cl,[cs:bx]		; shift
		mov	dl,[cs:bx + 1]		; mask (values - 1)
		mov	dh,[cs:menu_dsw]
		shr	dh,cl
		and	dh,dl			; DH: the value
		test	ax,K_RIGHT
		jz	.left
		inc	dh
		jmp	.wrap
.left:		dec	dh
.wrap:		and	dh,dl
		shl	dl,cl			; replace the field
		not	dl
		and	[cs:menu_dsw],dl
		shl	dh,cl
		or	[cs:menu_dsw],dh
.redraw:	test	ax,K_UP | K_DOWN | K_LEFT | K_RIGHT
		jz	.ret
		call	menu_build
		mov	ax,MENUSEG
		jmp	render_all
.close:		mov	byte [cs:menu_on],0
		mov	byte [cs:test_on],0
		call	sound_off
		push	ds
		mov	dx,Z80SEG
		mov	ds,dx
		xor	bx,bx			; restore the sound requests
.restore:	push	bx
		shr	bx,4
		mov	al,[cs:saved_reqs + bx]
		pop	bx
		mov	[SOUND_REQS + bx],al
		add	bx,10h
		cmp	bx,60h
		jb	.restore
		mov	al,[cs:menu_dsw]
		cmp	al,[cs:menu_old]
		je	.same
		mov	[DSW],al
		mov	byte [cs:restart],1
.same:		pop	ds
		mov	ax,Z80SEG		; the game's picture again
		jmp	render_all
.ret:		ret

; The sound test's native part, every frame of the screen (before the stub
; is injected): phase 0 clears every request, so that the program's sound
; routines stop every sound; phase 1 sets the selected test's requests;
; phase 2 keeps an alternating request going (sound 5) and plays
; the WSG registers.
test_frame:	cmp	byte [cs:test_on],0
		je	.ret
		push	ds
		mov	ax,Z80SEG
		mov	ds,ax
		mov	bl,[cs:test_sel]
		xor	bh,bh
		imul	bx,bx,TEST_SIZE
		add	bx,tests
		mov	al,[cs:test_phase]
		cmp	al,1
		je	.set
		ja	.run
		xor	si,si			; phase 0
.clear:		mov	byte [SOUND_REQS + si],0
		add	si,10h
		cmp	si,60h
		jb	.clear
		mov	byte [cs:test_phase],1
		mov	byte [cs:test_count],0
		jmp	.out
.set:		mov	si,[cs:bx + 2]		; phase 1
		or	si,si
		jz	.set2
		mov	al,[cs:bx + 4]
		mov	[si],al
.set2:		mov	si,[cs:bx + 5]
		or	si,si
		jz	.set3
		mov	al,[cs:bx + 7]
		mov	[si],al
.set3:		mov	byte [cs:test_phase],2
		jmp	.out
.run:		test	byte [cs:bx + 8],1	; phase 2: alternate the two
		jz	.out			; halves of sound 5
		inc	byte [cs:test_count]
		cmp	byte [cs:test_count],8
		jb	.out
		mov	byte [cs:test_count],0
		mov	si,[cs:bx + 2]
		xor	byte [si],03h
.out:		pop	ds
		call	sound
.ret:		ret

; Sound-test stub, copied to Z80 STUB_PC: what the interrupt routine does
; for sound (008Dh-00D4h, 01B9h-01BEh), without the demonstration-mode silencing
; of effect channels 1 and 2. Written independently of the routine's code
; (the distributed PK.COM must not contain ROM bytes): a byte loop for
; the copy, the waveform choice tested the other way round, IX and IY
; saved in the other order.
z80_stub:	db	0f5h, 0c5h, 0d5h, 0e5h	; push af, bc, de, hl
		db	0fdh, 0e5h, 0ddh, 0e5h	; push iy, ix
		db	11h, 50h, 50h		; ld de,5050h
		db	21h, 8ch, 4eh		; ld hl,4E8Ch
		db	06h, 10h		; ld b,16
		db	7eh			; 1: ld a,(hl)
		db	12h			; ld (de),a
		db	23h			; inc hl
		db	1ch			; inc e
		db	10h, 0fah		; djnz 1b
%assign w 0
%rep 3
		db	3ah, 0cch + w * 10h, 4eh	; ld a,(4ECCh + 16w): song?
		db	0b7h				; or a
		db	3ah, 9fh + w * 10h, 4eh		; ld a,(4E9Fh + 16w): effect
		db	28h, 03h			; jr z,+3
		db	3ah, 0cfh + w * 10h, 4eh	; ld a,(4ECFh + 16w): song
		db	32h, 45h + w * 5, 50h		; ld (5045h + 5w),a
%assign w w + 1
%endrep
		db	0cdh, 0ch, 2dh		; call 2D0Ch (effects)
		db	0cdh, 0c1h, 2ch		; call 2CC1h (songs)
		db	0ddh, 0e1h, 0fdh, 0e1h	; pop ix, iy
		db	0e1h, 0d1h, 0c1h, 0f1h	; pop hl, de, bc, af
		db	0fbh, 0c9h		; ei; ret
z80_stub_end:

; Version B dispatch, copied to Z80 IM2_STUB: the program uses interrupt
; mode 2 with I = 3Fh and the vector byte written by OUT (0),A; the patches
; (tools/patches.py) make both OUT (0),A into LD I,A, so I holds the vector
; and the interrupt goes through the word at 3F00h + I. Keeps every
; register.
im2_stub:	db	0e5h			; push hl
		db	0f5h			; push af
		db	0edh, 57h		; ld a,i
		db	6fh			; ld l,a
		db	26h, 3fh		; ld h,3Fh
		db	7eh			; ld a,(hl)
		db	2ch			; inc l
		db	66h			; ld h,(hl)
		db	6fh			; ld l,a
		db	0f1h			; pop af
		db	0e3h			; ex (sp),hl
		db	0c9h			; ret: to the routine
im2_stub_end:

; Tests (numbered on the screen): name, first request (address, value),
; second request, flags
; (bit 0: alternate the first request between 1 and 2 every 8 frames).
; Request bits from the program's use of them (tools/audit.py listing).
TEST_SIZE	equ	9
%macro TEST 6
		dw	%1
		dw	%2
		db	%3
		dw	%4
		db	%5
		db	%6
%endmacro
tests:		TEST	n_off, 0, 0, 0, 0, 0
		TEST	n_sound1, 4ecch, 1, 4edch, 1, 0
		TEST	n_sound2, 4ecch, 2, 4edch, 2, 0
		TEST	n_sound3, 4e9ch, 02h, 0, 0, 0
		TEST	n_sound4, 4e9ch, 01h, 0, 0, 0
		TEST	n_sound5, 4ebch, 01h, 0, 0, 1
		TEST	n_sound6, 4ebch, 04h, 0, 0, 0
		TEST	n_sound7, 4ebch, 08h, 0, 0, 0
		TEST	n_sound8, 4ebch, 10h, 0, 0, 0
		TEST	n_sound9, 4ebch, 20h, 0, 0, 0
		TEST	n_sound10, 4each, 01h, 0, 0, 0
		TEST	n_sound11, 4each, 02h, 0, 0, 0
		TEST	n_sound12, 4each, 04h, 0, 0, 0
		TEST	n_sound13, 4each, 08h, 0, 0, 0
		TEST	n_sound14, 4each, 10h, 0, 0, 0
		TEST	n_sound15, 4each, 20h, 0, 0, 0
		TEST	n_sound16, 4each, 40h, 0, 0, 0
		TEST	n_sound17, 4each, 80h, 0, 0, 0
TESTS		equ	($ - tests) / TEST_SIZE

n_off		db	'OFF             ', 0
n_sound1	db	'SOUND 1         ', 0
n_sound2	db	'SOUND 2         ', 0
n_sound3	db	'SOUND 3         ', 0
n_sound4	db	'SOUND 4         ', 0
n_sound5	db	'SOUND 5         ', 0
n_sound6	db	'SOUND 6         ', 0
n_sound7	db	'SOUND 7         ', 0
n_sound8	db	'SOUND 8         ', 0
n_sound9	db	'SOUND 9         ', 0
n_sound10	db	'SOUND 10        ', 0
n_sound11	db	'SOUND 11        ', 0
n_sound12	db	'SOUND 12        ', 0
n_sound13	db	'SOUND 13        ', 0
n_sound14	db	'SOUND 14        ', 0
n_sound15	db	'SOUND 15        ', 0
n_sound16	db	'SOUND 16        ', 0
n_sound17	db	'SOUND 17        ', 0

; Draw every tile that differs from the source AX's tile and colour RAM
; into the background, then copy the background to every page; no sprites.
render_all:	mov	[cs:src_seg],ax
		mov	word [cs:render_words],400h
		call	render
		mov	word [cs:src_seg],Z80SEG
		mov	word [cs:render_words],MAX_WORDS
		push	cs
		pop	es
		xor	ax,ax
		mov	di,queue_count
		mov	cx,PAGES
		rep	stosw
		mov	bx,rects
		mov	cx,PAGES
.rl:		mov	word [cs:bx],0
		add	bx,2 + MAX_RECTS * RECT
		loop	.rl
		mov	ds,[cs:bg_seg]
		xor	bx,bx
.page:		mov	es,[cs:page_seg + bx]
		xor	si,si
		xor	di,di
		mov	cx,LINES * LINE_BYTES / 2
		rep	movsw
		add	bx,2
		cmp	bx,PAGES * 2
		jb	.page
		ret

; Build the screen in MENUSEG: clear it, then the title, the items with
; the selected one in yellow, and the key help.
menu_build:	push	ds
		push	es
		mov	ax,MENUSEG
		mov	es,ax
		mov	di,4000h		; tiles: blank (40h)
		mov	cx,400h
		mov	al,40h
		rep	stosb
		xor	al,al			; colours: 0
		mov	cx,400h
		rep	stosb
		push	cs
		pop	ds
		mov	si,menu_fixed		; (gx, gy, palette, text, 0) records
.fixed:		lodsb
		cmp	al,0ffh
		je	.items
		mov	dl,al
		lodsb
		mov	dh,al
		lodsb
		mov	ah,al
		call	menu_text
		jmp	.fixed
.items:		xor	bx,bx			; BX: item
.item:		push	bx
		mov	ah,PAL_TEXT		; label
		mov	al,PAL_VALUE
		cmp	bl,[menu_sel]
		jne	.colour
		mov	ah,PAL_SELECT
		mov	al,PAL_SELECT
.colour:	mov	[value_pal],al
		imul	bx,bx,ITEM
		add	bx,items
		mov	dl,3			; label at gx 3
		mov	dh,[bx + 2]		; gy
		mov	si,[bx + 3]
		call	menu_text
		mov	cl,[bx]			; the value's text
		mov	al,[menu_dsw]
		shr	al,cl
		and	al,[bx + 1]
		xor	ah,ah
		shl	ax,1
		mov	si,[bx + 5]
		add	si,ax
		mov	si,[si]
		mov	dl,11			; value at gx 11
		mov	ah,[value_pal]
		call	menu_text
		pop	bx
		inc	bx
		cmp	bx,DSW_ITEMS
		jb	.item
		mov	bl,DSW_ITEMS		; SOUND
		mov	dh,SOUND_GY
		mov	si,t_sound
		mov	di,s_fm
		cmp	byte [sound_ssg],0
		je	.extra
		mov	di,s_ssg
.extra:		call	.line
		mov	bl,DSW_ITEMS + 1	; TEST
		mov	dh,TEST_GY
		mov	si,t_test
		mov	al,[test_sel]
		xor	ah,ah
		imul	di,ax,TEST_SIZE
		mov	di,[tests + di]
		call	.line
		pop	es
		pop	ds
		ret
; label SI and value DI at game row DH, item BL
.line:		mov	ah,PAL_TEXT
		mov	al,PAL_VALUE
		cmp	bl,[menu_sel]
		jne	.c
		mov	ah,PAL_SELECT
		mov	al,PAL_SELECT
.c:		mov	[value_pal],al
		mov	dl,3
		push	dx
		call	menu_text
		pop	dx
		mov	dl,11
		mov	si,di
		mov	ah,[value_pal]
		jmp	menu_text

; Text DS:SI (ASCII, upper case and digits, ended by 0) at game column DL
; (0-27, left to right), game row DH (2-33, top to bottom), palette AH, in
; ES (MENUSEG). Tile RAM offset = (29 - gx) * 32 + gy - 2. Leaves SI after
; the text.
menu_text:	push	bx
.ch:		lodsb
		or	al,al
		jz	.done
		cmp	al,' '
		jne	.put
		mov	al,40h			; the font's blank
.put:		mov	bl,29
		sub	bl,dl
		xor	bh,bh
		shl	bx,5
		add	bl,dh
		adc	bh,0
		sub	bx,2
		mov	[es:4000h + bx],al
		mov	[es:4400h + bx],ah
		inc	dl
		jmp	.ch
.done:		pop	bx
		ret

ITEM		equ	7		; shift, mask, gy, label, values table
SOUND_GY	equ	19
TEST_GY		equ	21
items:		db	0, 3, 8
		dw	t_coin, v_coin
		db	2, 3, 10
		dw	t_lives, v_lives
		db	4, 3, 12
		dw	t_bonus, v_bonus
		db	6, 1, 14
		dw	t_level, v_level
		db	7, 1, 16
		dw	t_names, v_names

v_coin		dw	s_free, s_1c1c, s_1c2c, s_2c1c
v_lives		dw	s_1, s_2, s_3, s_5
v_bonus		dw	s_10000, s_15000, s_20000, s_none
v_level		dw	s_hard, s_normal
v_names		dw	s_alt, s_normal

; Values are padded to 16 characters to cover the previous text.
t_coin		db	'COIN', 0
t_lives		db	'LIVES', 0
t_bonus		db	'BONUS', 0
t_level		db	'LEVEL', 0
t_names		db	'NAMES', 0
t_sound		db	'SOUND', 0
t_test		db	'TEST', 0
s_fm		db	'FM              ', 0
s_ssg		db	'SSG             ', 0
s_free		db	'FREE PLAY       ', 0
s_1c1c		db	'1 COIN 1 CREDIT ', 0
s_1c2c		db	'1 COIN 2 CREDITS', 0
s_2c1c		db	'2 COINS 1 CREDIT', 0
s_1		db	'1               ', 0
s_2		db	'2               ', 0
s_3		db	'3               ', 0
s_5		db	'5               ', 0
s_10000		db	'10000           ', 0
s_15000		db	'15000           ', 0
s_20000		db	'20000           ', 0
s_none		db	'NONE            ', 0
s_hard		db	'HARD            ', 0
s_normal	db	'NORMAL          ', 0
s_alt		db	'ALTERNATE       ', 0

menu_fixed:	db	8, 4, PAL_TITLE, 'DIP SWITCHES', 0
		db	3, 24, PAL_TEXT, '8 2  SELECT', 0
		db	3, 26, PAL_TEXT, '4 6  CHANGE', 0
		db	3, 28, PAL_TEXT, 'RET  PLAY TEST', 0
		db	3, 30, PAL_TEXT, 'F10  BACK TO GAME', 0
		db	3, 32, PAL_TEXT, 'DIP CHANGE RESTARTS', 0
		db	0ffh

; ---------------------------------------------------------------------------
; Sound: the board's WSG (wavetable sound generator) on the YM2203 (ports 44h/45h, technical manual 5.10),
; on the FM channels (sound_ssg = 0) or the SSG square waves (sound_ssg = 1,
; M06 stage A). WSG registers as in MAME's sound register handler (low nibbles):
; voice 0 frequency 5050h-5054h (20 bits), volume 5055h; voice 1 frequency
; 5056h-5059h (bits 4-19), volume 505Ah; voice 2 505Bh-505Eh, 505Fh;
; waveforms 5045h, 504Ah, 504Fh. The WSG plays its 32-sample wave at
; 96 kHz x F / 2^20. Voices 0-2 play on channels 1-3 (FM) or A-C (SSG).
; Registers are written only when they change.

WSG_TP_K_HIGH	equ	000ah		; SSG: TP = 681574 / F, 681574 = 000A6666h
WSG_TP_K_LOW	equ	6666h
F_LOW_LIMIT	equ	6292		; F of 576 Hz: below it the LOW voices

sound_init:	mov	al,2dh			; prescaler 1/6 (the reset default)
		mov	ah,0
		call	opn_write
%ifndef NO_FM
		call	fm_init
%endif
		mov	al,07h			; mixer: tones A-C on, noise off; the
		call	opn_read		; I/O port direction bits kept
		and	ah,0c0h
		or	ah,38h
		mov	al,07h
		call	opn_write
		; fall through

; Silence every channel and forget what was written, so that the next
; frame writes everything again.
sound_off:	push	ax
		push	bx
		xor	bx,bx
.ch:		mov	al,28h			; FM key off
		mov	ah,bl
		call	opn_write
		mov	al,08h			; SSG level 0
		add	al,bl
		mov	ah,0
		call	opn_write
		mov	byte [cs:fm_key + bx],0
		mov	byte [cs:fm_patch + bx],0ffh
		mov	byte [cs:ssg_level + bx],0
		shl	bx,1
		mov	word [cs:ssg_tp + bx],0ffffh
		shr	bx,1
		inc	bx
		cmp	bx,3
		jb	.ch
		pop	bx
		pop	ax
		ret

; Register AL = AH; keeps every register.
opn_write:	push	ax
		push	dx
		push	ax
		call	opn_wait
		pop	ax
		out	44h,al
		call	opn_wait
		mov	al,ah
		out	45h,al
		pop	dx
		pop	ax
		ret

; AH = register AL.
opn_read:	push	ax
		call	opn_wait
		pop	ax
		out	44h,al
		call	opn_wait
		in	al,45h
		mov	ah,al
		ret

opn_wait:	in	al,44h
		test	al,80h
		jnz	opn_wait
		ret

sound:		mov	ax,Z80SEG
		mov	ds,ax
		mov	si,5054h		; voice 0: 5 nibbles
		mov	cx,5
		xor	bx,bx			; channel 1 / A
		call	voice
		mov	si,5059h		; voice 1
		mov	cx,4
		mov	bx,1
		call	voice
		mov	si,505eh		; voice 2
		mov	cx,4
		mov	bx,2
		jmp	voice

; Play the voice whose frequency nibbles end at SI (CX of them, highest
; first; with 4 nibbles they are bits 4-19) and whose volume follows them,
; on channel BX (DS = Z80SEG).
voice:		push	bx
		mov	di,cx			; DI: nibble count
		xor	ax,ax			; DX:AX: F
		xor	dx,dx
.nib:		call	shl4
		mov	bl,[si]
		and	bx,000fh
		or	ax,bx
		dec	si
		loop	.nib
		cmp	di,4
		jne	.vol
		call	shl4
.vol:		add	si,di			; volume (5055h, 505Ah, 505Fh)
		mov	cl,[si + 1]
		and	cl,0fh
		pop	bx
%ifndef NO_FM
		cmp	byte [cs:sound_ssg],0
		je	fm_voice
%endif
		; SSG
		push	bx
		mov	bl,cl
		xor	bh,bh
		mov	cl,[cs:ssg_volume + bx]	; CL: SSG level
		pop	bx
		or	cl,cl
		jz	.level
		mov	si,ax
		or	si,dx
		jz	.silent
		mov	si,WSG_TP_K_LOW		; DI:SI = K, normalised with F
		mov	di,WSG_TP_K_HIGH	; to 16 bits
.norm:		or	dx,dx
		jz	.div
		shr	dx,1
		rcr	ax,1
		shr	di,1
		rcr	si,1
		jmp	.norm
.div:		or	ax,ax
		jz	.silent
		cmp	di,ax			; quotient over 16 bits: lowest tone
		jae	.max
		xchg	ax,si			; DX:AX = K, SI = F
		mov	dx,di
		div	si
		cmp	ax,0fffh
		jbe	.min
.max:		mov	ax,0fffh
.min:		or	ax,ax
		jnz	.tp
		inc	ax
.tp:		shl	bx,1			; write TP if it changed
		cmp	ax,[cs:ssg_tp + bx]
		je	.same
		mov	[cs:ssg_tp + bx],ax
		mov	dh,ah
		mov	ah,al
		mov	al,bl			; register 2 x channel: low byte
		call	opn_write
		inc	al
		mov	ah,dh
		call	opn_write
.same:		shr	bx,1
		jmp	.level
.silent:	xor	cl,cl
.level:		cmp	cl,[cs:ssg_level + bx]	; write the level if it changed
		je	.ret
		mov	[cs:ssg_level + bx],cl
		mov	al,08h
		add	al,bl
		mov	ah,cl
		call	opn_write
.ret:		ret

shl4:		shl	ax,1
		rcl	dx,1
		shl	ax,1
		rcl	dx,1
		shl	ax,1
		rcl	dx,1
		shl	ax,1
		rcl	dx,1
		ret

%ifndef NO_FM
; ---------------------------------------------------------------------------
; FM voices. Each WSG waveform has two fitted voices (tools/fmfit.py), LOW
; for F below F_LOW_LIMIT (576 Hz), with the buzz of the WSG's 32 held
; samples, and HIGH above; 9 bytes each at FM_VOICES: FB << 3 | ALG, then
; MUL and TL of operators 1-4. The envelope is flat (AR 31, no decay,
; RR 15): the key stays on while the WSG voice sounds, and the WSG volume
; is a TL offset on the carriers.
;
; Pitch: F-number x 2^(B-1) = 144 x f x 2^20 / 3993600 with f = 96000 x
; F / 2^20, that is F x 3.4615, taken as F x 443 / 128.

fm_init:	push	bx
		xor	bx,bx			; BX: channel
.ch:		xor	si,si			; SI: operator
.op:		mov	al,[cs:op_reg + si]
		add	al,bl
		push	ax
		add	al,30h			; DT 0, MUL 1
		mov	ah,01h
		call	opn_write
		pop	ax
		push	ax
		add	al,40h			; TL 127
		mov	ah,7fh
		call	opn_write
		pop	ax
		push	ax
		add	al,50h			; KS 0, AR 31
		mov	ah,1fh
		call	opn_write
		pop	ax
		push	ax
		add	al,60h			; D1R 0
		mov	ah,0
		call	opn_write
		pop	ax
		push	ax
		add	al,70h			; D2R 0
		mov	ah,0
		call	opn_write
		pop	ax
		push	ax
		add	al,80h			; SL 0, RR 15
		mov	ah,0fh
		call	opn_write
		pop	ax
		add	al,90h			; no SSG-type envelope
		mov	ah,0
		call	opn_write
		inc	si
		cmp	si,4
		jb	.op
		inc	bx
		cmp	bx,3
		jb	.ch
		pop	bx
		ret

; FM channel BX plays F = DX:AX at WSG volume CL (DS = Z80SEG).
fm_voice:	or	cl,cl
		jz	.off
		mov	si,ax
		or	si,dx
		jz	.off
		push	cx
		; CH: the voice, waveform x 2 + range
		imul	si,bx,5
		mov	ch,[5045h + si]
		and	ch,07h
		shl	ch,1
		or	dx,dx
		jnz	.high
		cmp	ax,F_LOW_LIMIT
		jb	.range
.high:		inc	ch
.range:		mov	[cs:fm_want],ch
		; DX:AX = F x 443 / 128
		mov	si,dx
		mov	di,443
		mul	di			; low word x 443
		push	ax
		push	dx
		mov	ax,si
		mul	di			; high word x 443 (F < 2^20: fits)
		pop	dx
		add	dx,ax
		pop	ax
		mov	cx,7
.s7:		shr	dx,1
		rcr	ax,1
		loop	.s7
		mov	cl,1			; CL: block
.blk:		or	dx,dx
		jnz	.up
		cmp	ax,2048
		jb	.fnum
.up:		shr	dx,1
		rcr	ax,1
		inc	cl
		jmp	.blk
.fnum:		cmp	cl,7
		jbe	.b
		mov	cl,7
		mov	ax,2047
.b:		shl	cl,3
		or	ah,cl			; AX: block << 11 | F-number
		pop	cx
		push	bx
		shl	bx,1
		cmp	ax,[cs:fm_fnum + bx]
		je	.samef
		mov	[cs:fm_fnum + bx],ax
		shr	bx,1
		mov	dx,ax
		mov	al,0a4h			; high byte (with block) first
		add	al,bl
		mov	ah,dh
		call	opn_write
		mov	al,0a0h
		add	al,bl
		mov	ah,dl
		call	opn_write
.samef:		pop	bx
		mov	al,[cs:fm_want]
		cmp	al,[cs:fm_patch + bx]
		je	.vol
		mov	[cs:fm_patch + bx],al
		call	fm_load
		jmp	.levels
.vol:		cmp	cl,[cs:fm_vol + bx]
		je	.key
.levels:	mov	[cs:fm_vol + bx],cl
		call	fm_levels
.key:		cmp	byte [cs:fm_key + bx],0
		jne	.ret
		mov	byte [cs:fm_key + bx],1
		mov	al,28h			; key on, all four operators
		mov	ah,0f0h
		or	ah,bl
		jmp	opn_write
.off:		cmp	byte [cs:fm_key + bx],0
		je	.ret
		mov	byte [cs:fm_key + bx],0
		mov	al,28h
		mov	ah,bl
		jmp	opn_write
.ret:		ret

; SI = the voice of channel BX (fm_patch) in the payload.
fm_voice_ptr:	mov	al,[cs:fm_patch + bx]
		xor	ah,ah
		imul	si,ax,9
		add	si,FM_VOICES
		ret

; Load channel BX's voice: algorithm, feedback, MULs (the levels follow).
fm_load:	push	cx
		call	fm_voice_ptr
		mov	al,0b0h
		add	al,bl
		mov	ah,[cs:si]
		call	opn_write
		xor	di,di
.op:		mov	al,30h
		add	al,[cs:op_reg + di]
		add	al,bl
		mov	ah,[cs:si + 1]		; MUL
		call	opn_write
		add	si,2
		inc	di
		cmp	di,4
		jb	.op
		pop	cx
		ret

; Write channel BX's four TLs at WSG volume CL: the voice's TL, plus on the
; carriers the volume's attenuation.
fm_levels:	push	cx
		push	bx
		mov	bl,cl
		xor	bh,bh
		mov	ch,[cs:fm_volume + bx]	; CH: the volume's attenuation
		pop	bx
		call	fm_voice_ptr
		mov	al,[cs:si]		; DL: the algorithm's carriers
		and	al,07h
		push	bx
		mov	bl,al
		xor	bh,bh
		mov	dl,[cs:carriers + bx]
		pop	bx
		xor	di,di
.op:		mov	al,[cs:si + 2]		; TL
		add	si,2
		test	dl,1
		jz	.mod
		add	al,ch
		cmp	al,7fh
		jbe	.mod
		mov	al,7fh
.mod:		shr	dl,1
		mov	ah,al
		mov	al,40h
		add	al,[cs:op_reg + di]
		add	al,bl
		call	opn_write
		inc	di
		cmp	di,4
		jb	.op
		pop	cx
		ret

%endif

; Switch between FM and SSG (F10 screen).
sound_toggle:	call	sound_off
%ifndef NO_FM
		xor	byte [cs:sound_ssg],1
%endif
		ret

; ---------------------------------------------------------------------------
; VRTC

; Own INT 0Ah and mask every ICU input but IR2: from here on no BIOS code
; runs.
vrtc_install:	push	es
		xor	ax,ax
		mov	es,ax
		mov	word [es:VRTC_VEC * 4],vrtc
		mov	[es:VRTC_VEC * 4 + 2],cs
		pop	es
		mov	al,0fbh
		mov	dx,ICU1
		out	dx,al
		ret

vrtc:		push	ax
		push	bx
		push	dx
		push	ds
		inc	word [cs:ticks]
		mov	bx,sp			; [bx+8] IP, [bx+10] CS, [bx+12] PSW
		cmp	word [ss:bx + 10],Z80SEG
		jne	.eoi			; not the program: nothing to do
		call	frame
		cmp	byte [cs:restart],0
		je	.run
		mov	byte [cs:restart],0	; restart the program at 0000h, DI
		mov	word [ss:bx + 8],0000h
		and	word [ss:bx + 12],0fdffh
		jmp	.eoi
.run:		mov	dx,[cs:isr_entry]	; the program's interrupt routine
		cmp	byte [cs:menu_on],0	; paused: only the sound test's stub
		je	.inject
		cmp	byte [cs:test_on],0
		je	.eoi
		mov	dx,STUB_PC
.inject:	mov	ax,Z80SEG
		mov	ds,ax
		test	byte [5000h],1		; the program's interrupt enable
		jz	.eoi
		sub	bp,2			; Z80 PUSH PC; PC = DX; DI
		mov	ax,[ss:bx + 8]
		mov	[ds:bp],ax
		mov	[ss:bx + 8],dx
		and	word [ss:bx + 12],0fdffh
.eoi:		mov	al,20h
		mov	dx,ICU0
		out	dx,al
		pop	ds
		pop	dx
		pop	bx
		pop	ax
		iret

; The frame's native work, before the program's interrupt routine runs.
; Keeps every register but AX, DX and DS (BP is the Z80 stack pointer).
; First the page drawn in the previous frame is shown (its DSA takes effect
; before the picture starts); then the other page is drawn.
frame:		pusha
		push	es
		call	scan_keys
		mov	bx,[cs:keys_held]
		mov	[cs:keys_held],ax
		not	bx
		and	bx,ax
		mov	[cs:keys_new],bx
		test	bx,K_ESC
		jz	.noesc
		call	sound_off		; ESC: restart the machine
		mov	al,20h
		mov	dx,ICU0
		out	dx,al
		jmp	0ffffh:0000h
.noesc:
%ifdef KEY_DIAG
		call	key_diag
%endif
		cmp	byte [cs:menu_on],0
		je	.game
		call	menu_frame
		jmp	.done
.game:		test	bx,K_F10
		jz	.play
		call	sound_off
		call	menu_open
		jmp	.done
.play:		call	inputs
		call	show_page
		inc	byte [cs:back]
		cmp	byte [cs:back],PAGES
		jb	.next
		mov	byte [cs:back],0
.next:		mov	bl,[cs:back]
		xor	bh,bh
		shl	bx,1
		mov	ax,[cs:page_seg + bx]
		mov	[cs:draw_seg],ax
		call	sprite_regs
		call	apply_queue
		call	erase_sprites
		call	render
		call	sprites
		call	sound
.done:
%ifdef DEBUG_DUMP
		; Copy tile and colour RAM after the display areas, for vaeg's GVRAM
		; capture (tools/gvram_png.py).
		mov	ax,Z80SEG
		mov	ds,ax
		mov	ax,[cs:gvram_seg]
		add	ax,DUMP_PARAS
		mov	es,ax
		xor	di,di
		mov	si,TILE_RAM
		mov	cx,800h / 2
		rep	movsw
		mov	si,5040h		; then the WSG registers and the SSG
		mov	cx,20h / 2		; values (tp, level)
		rep	movsw
		push	cs
		pop	ds
		mov	si,ssg_tp		; through fm_fnum
		mov	cx,(fm_fnum + 6 - ssg_tp) / 2
		rep	movsw
%endif
		pop	es
		popa
		ret

; ---------------------------------------------------------------------------
; Data

s_fail		db	'Graphics BIOS call failed.', 13, 10, 0
s_24khz		db	'The machine is running at 24 kHz.', 13, 10
		db	'This game needs 15 kHz (320x224, 15.98 kHz) and a monitor', 13, 10
		db	'that accepts it. Restart the PC-88VA in 15 kHz mode', 13, 10
		db	'(CRT mode: DIP switch SW1 off).', 13, 10, 0

; SYNC: 15.98 kHz, TBL 37, 224 active lines, bottom 2, sync 4
sync224		db	0c1h, 57h, 1ch, 00h, 9fh, 00h, 10h, 0fh, 25h, 00h, 0e0h, 00h, 02h, 04h
		align	2
fb_desc		dw	4, 320, LINES, 0, 0, 0
gvram_seg	dw	0		; screen 0
bg_seg		dw	0		; picture origins of the three areas
page_seg	times PAGES dw 0
page_dsa	times PAGES dd 0	; GVRAM offsets of the pages' origins
draw_seg	dw	0		; the page being drawn
isr_entry	dw	0038h		; Z80 address the interrupt is injected to
shift_x		dw	0		; picture position: dots right
shift_y		dw	0		; lines down
ticks		dw	0
budget		dw	0
src_seg		dw	Z80SEG		; render's source of tile and colour RAM
render_words	dw	MAX_WORDS	; render's budget
ssg_tp		times 3 dw 0		; SSG values written (TP, level)
ssg_level	times 3 db 0
fm_patch	times 3 db 0		; FM channel state: the voice loaded,
fm_vol		times 3 db 0		; the volume, the key
fm_key		times 3 db 0
fm_want		db	0
%if %isdef(SOUND_SSG) || %isdef(NO_FM)
sound_ssg	db	1		; 0 FM, 1 SSG
%else
sound_ssg	db	0
%endif
op_reg		db	0, 8, 4, 0ch	; register offsets of operators 1-4
carriers	db	08h, 08h, 08h, 08h, 0ah, 0eh, 0eh, 0fh	; by algorithm, bit 0 = op 1
; WSG volume (linear, 1-15) -> TL attenuation, 0.75 dB a step
fm_volume	db	127, 31, 23, 19, 15, 13, 11, 9, 7, 6, 5, 4, 3, 2, 1, 0
		align	2
fm_fnum		times 3 dw 0
; WSG volume (linear, 0-15) -> SSG level (about 1.5-3 dB a step)
ssg_volume	db	0, 6, 8, 9, 10, 11, 11, 12, 12, 13, 13, 13, 14, 14, 15, 15
		align	2
keys_held	dw	0
keys_new	dw	0
align_left	dw	0
queue_count	times PAGES dw 0
queue		times PAGES * MAX_QUEUE dw 0
s_x		times 8 dw 0		; sprite registers of this frame
s_y		times 8 dw 0
s_attr		times 8 db 0
s_colour	times 8 db 0
back		db	0		; page being drawn (shown at the next VRTC)
keys_prev	db	0
menu_on		db	0
menu_sel	db	0
menu_dsw	db	0
menu_old	db	0
value_pal	db	0
restart		db	0
test_on		db	0		; sound test: running, selection,
test_sel	db	0		; phase, frame count
test_phase	db	0
test_count	db	0
saved_reqs	times 6 db 0
d_attr		db	0		; the sprite being drawn
d_colour	db	0
d_odd		db	0
d_column	db	0
		align	2
d_x		dw	0
d_y		dw	0
d_rows		dw	0
d_first		dw	0
d_step		dw	0
d_table		dw	0
d_groups	dw	0
rects		times PAGES * (2 + MAX_RECTS * RECT) db 0	; per page: count, list

		times	ROM_OFFSET - ($ - $$) db 0	; fails if the code is too large
