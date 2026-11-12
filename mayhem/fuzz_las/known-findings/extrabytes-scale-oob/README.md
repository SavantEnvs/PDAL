# LAS ExtraBytes VLR with more than 3 fields indexes `double[3]` out of bounds

`io/private/las/Utils.cpp:338` indexes `m_scale[]`/`m_offset[]` (both `double[3]`) with the
field index of an ExtraBytes spec whose `m_fieldCnt` is attacker controlled (up to 3 per the
LAS spec, not enforced). `reproducer.las` is `test/data/las/extrabytes.las` with one byte of the
extra-bytes descriptor mutated.

    ./fuzz_las-standalone mayhem/fuzz_las/known-findings/extrabytes-scale-oob/reproducer.las
    # runtime error: index 3 out of bounds for type 'double[3]'

Fix: reject (or clamp) an ExtraBytes spec whose field count is greater than 3 before it is used
to index the scale/offset arrays.
