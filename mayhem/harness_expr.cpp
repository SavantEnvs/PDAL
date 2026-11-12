// Runs a PDAL filter whose single option is the fuzzer's bytes (an expression or assignment
// string) over a small synthetic point cloud from readers.faux.
// Built per filter with -DPDAL_FILTER=<filters.x> -DFILTER_OPTION=<option name>.
#include <pdal/PointTable.hpp>
#include <pdal/Options.hpp>
#include <pdal/Stage.hpp>
#include <pdal/StageFactory.hpp>

#include <cstdint>
#include <string>

#ifndef PDAL_FILTER
#error "define PDAL_FILTER"
#endif
#ifndef FILTER_OPTION
#error "define FILTER_OPTION"
#endif

extern "C" int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size)
{
    try
    {
        pdal::StageFactory factory(false);

        pdal::Options ro;
        ro.add("mode", "ramp");
        ro.add("count", 20);
        ro.add("bounds", "([0, 100], [0, 100], [0, 100])");
        pdal::Stage *reader = factory.createStage("readers.faux");
        reader->setOptions(ro);

        pdal::Options fo;
        fo.add(FILTER_OPTION, std::string(reinterpret_cast<const char *>(data), size));
        pdal::Stage *filter = factory.createStage(PDAL_FILTER);
        filter->setOptions(fo);
        filter->setInput(*reader);

        pdal::PointTable table;
        filter->prepare(table);
        filter->execute(table);
    }
    catch (const std::exception &)
    {
        return -1;
    }
    return 0;
}
