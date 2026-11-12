// Parses a PDAL pipeline JSON document into a stage graph (no execution, so no file or network
// access happens beyond what option processing does).
#include <pdal/PipelineManager.hpp>

#include <cstdint>
#include <sstream>
#include <string>

extern "C" int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size)
{
    std::istringstream in(std::string(reinterpret_cast<const char *>(data), size));
    try
    {
        pdal::PipelineManager mgr;
        mgr.readPipeline(in);
    }
    catch (const std::exception &)
    {
        return -1;
    }
    return 0;
}
