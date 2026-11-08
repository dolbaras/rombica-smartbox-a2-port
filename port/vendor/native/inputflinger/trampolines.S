@ The original EventHub::mapKey of SlimBOX's libinputflinger, entered after its first
@ instruction (which the hook replaced by a branch to the new code): it is repeated here, then
@ the original code continues.
    .syntax unified
    .thumb
    .text

    .global orig_map_key
    .type orig_map_key, %function
    .thumb_func
orig_map_key:
    push    {r4, r5, r6, r7, r8, r9, sl, fp, lr}  @ 0x20468: e92d 4ff0
    b.w     map_key_rest                          @ 0x2046c
