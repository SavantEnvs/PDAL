// Generic PDAL reader harness: stages the fuzzer's bytes as a scratch file with the driver's
// extension and runs the real reader (prepare + execute) over it.
// Built once per reader with -DPDAL_DRIVER=<readers.x> -DFILE_EXT=<.ext>.
#include <pdal/PointTable.hpp>
#include <pdal/Options.hpp>
#include <pdal/Stage.hpp>
#include <pdal/StageFactory.hpp>
#include <pdal/pdal_types.hpp>

#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <string>
#include <unistd.h>

#ifndef PDAL_DRIVER
#error "define PDAL_DRIVER"
#endif
#ifndef FILE_EXT
#error "define FILE_EXT"
#endif

namespace
{
std::string writeScratch(const uint8_t *data, size_t size)
{
    const char *dir = getenv("TMPDIR");
    std::string path = std::string(dir && *dir ? dir : "/tmp") + "/pdalfuzzXXXXXX" FILE_EXT;
    int fd = mkstemps(&path[0], (int)sizeof(FILE_EXT) - 1);
    if (fd < 0)
        return std::string();
    size_t off = 0;
    while (off < size)
    {
        ssize_t n = write(fd, data + off, size - off);
        if (n <= 0)
            break;
        off += (size_t)n;
    }
    close(fd);
    return path;
}
}

extern "C" int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size)
{
    std::string path = writeScratch(data, size);
    if (path.empty())
        return -1;

    int rc = 0;
    try
    {
        pdal::StageFactory factory(false);
        pdal::Stage *reader = factory.createStage(PDAL_DRIVER);
        pdal::Options opts;
        opts.add("filename", path);
        reader->setOptions(opts);
        pdal::PointTable table;
        reader->prepare(table);
        reader->execute(table);
    }
    catch (const std::exception &)
    {
        rc = -1;
    }
    unlink(path.c_str());
    return rc;
}
