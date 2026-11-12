# readers.obj: face line with no vertex indices indexes an empty vector

`ObjReader::extractVertex` (`io/ObjReader.cpp`, called from `extractFace` / `readFace`) takes
`v[0]` of a split-string vector that is empty for a malformed `f` record. UBSan halts with
"reference binding to null pointer of type 'std::basic_string<char>'".

    ./fuzz_obj-standalone mayhem/fuzz_obj/known-findings/extractvertex-empty-vector/reproducer.obj
