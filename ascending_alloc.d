import std.experimental.allocator.building_blocks.null_allocator;

@safe @nogc nothrow pure
size_t roundUpToMultipleOf(size_t s, uint base)
{
    assert(base);
    auto rem = s % base;
    return rem ? s + base - rem : s;
}

struct AscendingAllocator
{
    import std.bitmanip : BitArray;
    import std.experimental.allocator.mallocator : Mallocator;

    size_t numPages;
    enum size_t pageSize = 4096;
    void* data;
    void* offset;
    size_t pagesUsed;
    bool valid;

    // Receives as a parameter the size in pages for each arena 
    version(Posix)
    {
        this(size_t pages)
        {
            import core.sys.posix.sys.mman : mmap, MAP_ANON, PROT_READ,
                   PROT_WRITE, PROT_NONE, MAP_PRIVATE, MAP_FAILED;
            import std.exception : enforce;

            valid = true;
            numPages = pages;
            data = mmap(null, pageSize * pages, PROT_NONE, MAP_PRIVATE | MAP_ANON, -1, 0);
            enforce(data != MAP_FAILED, "Failed to mmap memory");
            offset = data;
        }
    }
    else version(Windows)
    {
        this(size_t pages)
        {
            import core.sys.windows.windows : VirtualAlloc, PAGE_NOACCESS,
                   MEM_COMMIT, MEM_RESERVE;
            import std.exception : enforce;

            valid = true;
            numPages = pages;
            data = VirtualAlloc(null, pageSize * pages, MEM_COMMIT | MEM_RESERVE, PAGE_NOACCESS);
            enforce(data != null, "Failed to VirtualAlloc memory");
            offset = data;
        }
    }

    // Allocate multiple of page size, by changing page protection inside the arena
    version(Posix)
    {
        void[] allocate(size_t n)
        {
            import core.sys.posix.sys.mman : mmap, mprotect,
                   MAP_PRIVATE, MAP_ANON, MAP_FAILED, PROT_NONE, PROT_WRITE, PROT_READ;
            import std.exception : enforce;

            // If the requested size exceeds available space in current arena,
            // create new arena
            size_t goodSize = goodAllocSize(n);
            if (offset - data > numPages * pageSize - goodSize)
                return null;

            void* result = offset;
            offset += goodSize;
            pagesUsed += goodSize / pageSize;

            // Give memory back just by changing page protection
            auto ret = mprotect(result, goodSize, PROT_WRITE | PROT_READ);
            enforce(ret == 0, "Failed to allocate memory, mprotect failure"); 

            return cast(void[]) result[0 .. n];
        }
    }
    else version(Windows)
    {
        void[] allocate(size_t n)
        {
            import core.sys.windows.windows : VirtualProtect, PAGE_READWRITE;
            import std.exception : enforce;

            uint oldProtect;
            size_t goodSize = goodAllocSize(n);
            if (offset - data > numPages * pageSize - goodSize)
                return null;

            void *result = offset;
            offset += goodSize;
            pagesUsed += goodSize / pageSize;

            auto ret = VirtualProtect(result, goodSize, PAGE_READWRITE, &oldProtect);
            enforce(ret == 0, "Failed to allocate memory, VirtualProtect failure");

            return cast(void[]) result[0 .. n];
        }
    }

    size_t goodAllocSize(size_t n)
    {
        return n.roundUpToMultipleOf(pageSize);
    }


    version(Posix)
    {
        bool deallocate(void[] buf)
        {
            import core.sys.posix.sys.mman : posix_madvise, POSIX_MADV_DONTNEED, mprotect, PROT_NONE;
            import core.sys.posix.sys.mman : munmap, mprotect, PROT_NONE;
            import std.exception : enforce;

            size_t goodSize = goodAllocSize(buf.length);
            auto ret = mprotect(buf.ptr, goodSize, PROT_NONE);
            enforce(ret == 0, "Failed to deallocate memory, mprotect failure"); 

            // We might need madvise to let the OS reclaim the resources
            ret = posix_madvise(buf.ptr, goodSize, POSIX_MADV_DONTNEED); 
            enforce(ret == 0, "Failed to deallocate, posix_madvise failure");
            pagesUsed -= goodSize / pageSize;

            // unmap the arena if we don't use it anymore and it doesn't hold any alive objects
            if (!valid && pagesUsed == 0)
            {
                munmap(data, numPages * pageSize);
                data = null;
            }

            return true;
        }
    }
    else version(Windows)
    {
        bool deallocate(void[] buf)
        {
            import core.sys.windows.windows : VirtualUnlock, VirtualProtect,
                   VirtualFree, PAGE_NOACCESS, MEM_RELEASE;
            import std.exception : enforce;

            uint oldProtect;
            size_t goodSize = goodAllocSize(buf.length);
            auto ret = VirtualProtect(buf.ptr, goodSize, PAGE_NOACCESS, &oldProtect);
            enforce(ret == 0, "Failed to deallocate memory, VirtualProtect failure");

            VirtualUnlock(buf.ptr, goodSize);
            pagesUsed -= goodSize / pageSize;

            if (!valid && pagesUsed == 0)
            {
                VirtualFree(data, 0, MEM_RELEASE);
                data = null;
            }

            return true;
        }
    }

    bool owns(void[] buf)
    {
        return buf.ptr >= data && buf.ptr < buf.ptr + numPages * pageSize;
    }

    version(Posix)
    {
        void invalidate()
        {
            import core.sys.posix.sys.mman : munmap;
            valid = false;
            if (pagesUsed == 0) { 
                munmap(data, numPages * pageSize);
                data = null;
            }
        }
    }
    else version(Windows)
    {
        void invalidate()
        {
            import core.sys.windows.windows : VirtualFree, MEM_RELEASE;
            valid = false;
            if (pagesUsed == 0) {
                VirtualFree(data, 0, MEM_RELEASE);
                data = null;
            }
        }
    }

    size_t getAvailableSize()
    {
        return numPages * pageSize + data - offset;
    }
}

void main()
{

}
