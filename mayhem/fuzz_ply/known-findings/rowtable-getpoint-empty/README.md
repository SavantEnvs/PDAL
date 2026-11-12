# readers.ply writes into a point table that has no rows

`RowPointTable::getPoint` (`pdal/PointTable.cpp:121`) indexes an empty `std::vector<char*>`
when the reader sets a field before any point storage exists (reached from
`PointRef::setField` in the PLY reader). Under UBSan this halts with
"reference binding to null pointer of type 'char *'".

    ./fuzz_ply-standalone mayhem/fuzz_ply/known-findings/rowtable-getpoint-empty/reproducer.ply
