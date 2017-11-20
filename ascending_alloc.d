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
    size_t numPages;
    enum size_t pageSize = 4096;
    void* data;
    void* offset;
    size_t pagesUsed;
    bool valid;

    this(size_t pages)
    {
        import std.exception : enforce;

        valid = true;
        numPages = pages;
        version(Posix)
        {
            import core.sys.posix.sys.mman : mmap, MAP_ANON, PROT_READ,
                   PROT_WRITE, PROT_NONE, MAP_PRIVATE, MAP_FAILED;
            data = mmap(null, pageSize * pages, PROT_NONE, MAP_PRIVATE | MAP_ANON, -1, 0);
            enforce(data != MAP_FAILED, "Failed to mmap memory");
        }
        else version(Windows)
        {
            import core.sys.windows.windows : VirtualAlloc, PAGE_NOACCESS,
                   MEM_COMMIT, MEM_RESERVE;
            data = VirtualAlloc(null, pageSize * pages, MEM_COMMIT | MEM_RESERVE, PAGE_NOACCESS);
            enforce(data != null, "Failed to VirtualAlloc memory");
        }
        offset = data;

    }

    // Allocate multiple of page size, by changing page protection inside the arena
    void[] allocate(size_t n)
    {
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
        version(Posix)
        {
            import core.sys.posix.sys.mman : mmap, mprotect,
                   MAP_PRIVATE, MAP_ANON, MAP_FAILED, PROT_NONE, PROT_WRITE, PROT_READ;
            auto ret = mprotect(result, goodSize, PROT_WRITE | PROT_READ);
            enforce(ret == 0, "Failed to allocate memory, mprotect failure"); 
        }
        else version(Windows)
        {
            import core.sys.windows.windows : VirtualProtect, PAGE_READWRITE;
            uint oldProtect;
            auto ret = VirtualProtect(result, goodSize, PAGE_READWRITE, &oldProtect);
            enforce(ret != 0, "Failed to allocate memory, VirtualProtect failure");
        }

        return cast(void[]) result[0 .. n];
    }

    size_t goodAllocSize(size_t n)
    {
        return n.roundUpToMultipleOf(pageSize);
    }


    version(Posix)
    {
        bool deallocate(void[] buf)
        {
            import core.sys.posix.sys.mman : posix_madvise, POSIX_MADV_DONTNEED, mprotect, PROT_NONE, munmap;
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
            enforce(ret != 0, "Failed to deallocate memory, VirtualProtect failure");

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

    void invalidate()
    {
        valid = false;
        if (pagesUsed == 0) { 
            version(Posix)
            {
                import core.sys.posix.sys.mman : munmap;
                munmap(data, numPages * pageSize);
            }
            else version(Windows)
            {
                import core.sys.windows.windows : VirtualFree, MEM_RELEASE;
                VirtualFree(data, 0, MEM_RELEASE);
            }
            data = null;
        }
    }

    size_t getAvailableSize()
    {
        return numPages * pageSize + data - offset;
    }

    bool expand(ref void[] b, size_t delta)
    {
        import std.exception : enforce;

        if (!delta) return true;
        if (!b.ptr) return false;

        size_t goodSize = goodAllocSize(b.length);
        if (b.ptr + goodSize != offset)
            return false;

        size_t extraPages = 0;
        size_t bytesLeftOnPage = goodSize - b.length;

        if (delta > bytesLeftOnPage)
        {
            extraPages = goodAllocSize(delta - bytesLeftOnPage) / pageSize;
        }
        else
        {
            b = cast(void[]) b.ptr[0 .. b.length + delta];
            return true;
        }

        if (extraPages > numPages)
            return false;

        if (offset - data > pageSize * (numPages - extraPages))
            return false;

        version(Posix)
        {
            import core.sys.posix.sys.mman : mprotect, PROT_READ, PROT_WRITE;
            auto ret = mprotect(offset, extraPages * pageSize, PROT_READ | PROT_WRITE);
            enforce(ret == 0, "Failed to expand, mprotect failure");
        }
        else version(Windows)
        {
            import core.sys.windows.windows : VirtualProtect, PAGE_READWRITE;
            uint oldProtect;
            auto ret = VirtualProtect(offset, extraPages * pageSize, PAGE_READWRITE, &oldProtect);
            enforce(ret != 0, "Failed to expand, VirtualProtect failure");
        }

        pagesUsed += extraPages;
        offset += extraPages * pageSize;
        b = cast(void[]) b.ptr[0 .. b.length + delta];
        return true;
    }

    bool reallocate(ref void[] b, size_t newSize)
    {
        if (!newSize) return deallocate(b);
        if (!b) return true;

        if (newSize >= b.length && expand(b, newSize - b.length))
            return true;
        
        void[] newB = allocate(newSize);
        if (newB.length <= b.length) newB[] = b[0 .. newB.length];
        else newB[0 .. b.length] = b[];
        deallocate(b);
        b = newB;
        return true;
    }
}

@system unittest
{
    static void testrw(void[] b)
    {
        ubyte* buf = cast(ubyte*) b.ptr;
        buf[0] = 100;
        assert(buf[0] == 100);
        buf[b.length - 1] = 101;
        assert(buf[b.length - 1] == 101);
    }

    AscendingAllocator a = AscendingAllocator(4);
    void[] b1 = a.allocate(1);
    assert(a.getAvailableSize() == 3 * 4096);
    testrw(b1);

    void[] b2 = a.allocate(2);
    assert(a.getAvailableSize() == 2 * 4096);
    testrw(b2);

    void[] b3 = a.allocate(4097);
    assert(a.getAvailableSize() == 0);
    testrw(b3);

    assert(b1.length == 1);
    assert(b2.length == 2);
    assert(b3.length == 4097);

    assert(a.offset - a.data == 4 * 4096);
    void[] b4 = a.allocate(4);
    assert(!b4);
    a.invalidate();

    a.deallocate(b1);
    assert(a.data);
    a.deallocate(b2);
    assert(a.data);
    a.deallocate(b3);
    assert(!a.data);
}

@system unittest
{
    static void testrw(void[] b)
    {
        ubyte* buf = cast(ubyte*) b.ptr;
        buf[0] = 100;
        buf[b.length - 1] = 101;

        assert(buf[0] == 100);
        assert(buf[b.length - 1] == 101);
    }

    size_t numPages = 26214;
    AscendingAllocator a = AscendingAllocator(numPages);
    for (int i = 0; i < numPages; i++) {
        void[] buf = a.allocate(4096);
        assert(buf.length == 4096);
        testrw(buf);
        a.deallocate(buf);
    }

    assert(!a.allocate(1));
    assert(a.getAvailableSize() == 0);
    a.invalidate();
    assert(!a.data);
}

@system unittest
{
    static void testrw(void[] b)
    {
        ubyte* buf = cast(ubyte*) b.ptr;
        buf[0] = 100;
        buf[b.length - 1] = 101;

        assert(buf[0] == 100);
        assert(buf[b.length - 1] == 101);
    }

    size_t numPages = 5;
    enum pageSize = 4096;
    AscendingAllocator a = AscendingAllocator(numPages);

    void[] b1 = a.allocate(2048);
    assert(b1.length == 2048);
    
    void[] b2 = a.allocate(2048);
    assert(!a.expand(b1, 1));
    assert(a.expand(b1, 0));
    testrw(b1);

    assert(a.expand(b2, 2048));
    testrw(b2);
    assert(b2.length == pageSize);
    assert(a.getAvailableSize() == pageSize * 3);

    void[] b3 = a.allocate(2048);
    assert(a.reallocate(b1, b1.length));
    assert(a.reallocate(b2, b2.length));
    assert(a.reallocate(b3, b3.length));

    assert(b3.length == 2048);
    testrw(b3);
    assert(a.expand(b3, 1000));
    testrw(b3);
    assert(a.expand(b3, 0));
    assert(b3.length == 3048);
    assert(a.expand(b3, 1047));
    testrw(b3);
    assert(a.expand(b3, 0));
    assert(b3.length == 4095);
    assert(a.expand(b3, 100));
    assert(a.expand(b3, 0));
    assert(a.getAvailableSize() == pageSize);
    assert(b3.length == 4195);
    testrw(b3);

    assert(a.reallocate(b1, b1.length));
    assert(a.reallocate(b2, b2.length));
    assert(a.reallocate(b3, b3.length));
    
    assert(a.reallocate(b3, 2 * pageSize));
    testrw(b3);
    assert(a.reallocate(b1, pageSize - 1));
    testrw(b1);
    assert(a.expand(b1, 1));
    testrw(b1);
    assert(!a.expand(b1, 1));

    a.invalidate();
    a.deallocate(b1);
    a.deallocate(b2);
    a.deallocate(b3);
    assert(!a.data);
}

@system unittest
{

}

void main()
{
}
