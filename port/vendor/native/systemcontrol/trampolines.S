@ The original DisplayMode::getPosition / setPosition / getBestHdmiDeepColorAttr of SlimBOX's
@ systemcontrol, entered after their first instruction (which the hook replaced by a branch to the
@ new code): it is repeated here, then the original code continues. All three first instructions
@ are plain register pushes.
    .syntax unified
    .thumb
    .text

    .global orig_get_position
    .type orig_get_position, %function
    .thumb_func
orig_get_position:                  @ DisplayMode::getPosition(const char *mode, int *position)
    push    {r4, r5, r6, r7, r8, r9, lr}        @ 0x2115c: e92d 43f0
    b.w     get_position_rest                   @ 0x21160

    .global orig_set_position
    .type orig_set_position, %function
    .thumb_func
orig_set_position:                  @ DisplayMode::setPosition(mode, left, top, width, height)
    push    {r4, r5, r6, r7, r8, r9, sl, fp, lr} @ 0x21c04: e92d 4ff0
    b.w     set_position_rest                   @ 0x21c08

    .global orig_best_color
    .type orig_best_color, %function
    .thumb_func
orig_best_color:                    @ DisplayMode::getBestHdmiDeepColorAttr(outputmode, colorAttribute)
    push    {r4, r5, r6, r7, r8, r9, sl, fp, lr} @ 0x2ae7c: e92d 4ff0
    b.w     best_color_rest                     @ 0x2ae80
