import std.experimental.allocator.building_blocks.null_allocator;

@safe @nogc nothrow pure
size_t roundUpToMultipleOf(size_t s, uint base)
{
    assert(base);
    auto rem = s % base;
    return rem ? s + base - rem : s;
}

struct AscendingAllocator(ParentAllocator = NullAllocator)
{
    import std.bitmanip : BitArray;
    import std.experimental.allocator.mallocator : Mallocator;

    // Allocator uses a list of ArenaNodes, which are ranges of virtual addresses
    struct ArenaNode
    {
        ArenaNode* next;
        ArenaNode* prev;
        void* offset;
        void* data;
        bool valid;
        size_t pagesUsed;
    }

    size_t numPages;
    enum size_t pageSize = 4096;
    enum size_t allocLimit = 2048;
    ArenaNode *currentArena;
    ArenaNode *headArena;

    // Use parent to allocate metadata for arenas
    static if (is(ParentAllocator == NullAllocator)) alias parent = Mallocator.instance;
    else
    {
        static if (stateSize!ParentAllocator) ParentAllocator parent;
        else alias parent = ParentAllocator.instance;
    }

    // Receives as a parameter the size in pages for each arena 
    this(size_t pages)
    {
        import core.sys.posix.sys.mman : mmap, MAP_ANON, PROT_READ,
               PROT_WRITE, PROT_NONE, MAP_PRIVATE, MAP_FAILED;
        import std.exception : enforce;

        headArena = currentArena = cast(ArenaNode*) parent.allocate(ArenaNode.sizeof);
        currentArena.valid = true;
        currentArena.next = currentArena.prev = currentArena;
        numPages = pages;
        void* data = mmap(null, pageSize * pages, PROT_NONE, MAP_PRIVATE | MAP_ANON, -1, 0);
        enforce(data != MAP_FAILED, "Failed to reserve memory");
        currentArena.offset = data;
        currentArena.data = data;
        currentArena.pagesUsed = 0;
    }

    private void[] allocateSmall(size_t n)
    {
        //TODO
        return null;
    }

    // Create new arena and add it at the end of the list
    private ArenaNode* createArena()
    {
        import core.sys.posix.sys.mman : mmap, MAP_PRIVATE, MAP_ANON, MAP_FAILED, PROT_NONE;
        import std.exception : enforce;

        ArenaNode* newArena = cast(ArenaNode*) parent.allocate(ArenaNode.sizeof);
        void* data = mmap(null, pageSize * numPages, PROT_NONE, MAP_PRIVATE | MAP_ANON, -1, 0);
        enforce(data != MAP_FAILED, "Failed to reserve memory");

        newArena.valid = true;
        newArena.data = data;
        newArena.offset = data;
        newArena.prev = currentArena;
        newArena.next = headArena;

        currentArena.next = newArena;
        headArena.prev = newArena;

        currentArena.valid = false;
        currentArena = newArena;

        return currentArena;
    }

    // Allocate multiple of page size, by changing page protection inside the arena
    private void[] allocateLarge(size_t n)
    {
        import core.sys.posix.sys.mman : mmap, mprotect,
               MAP_PRIVATE, MAP_ANON, MAP_FAILED, PROT_NONE, PROT_WRITE, PROT_READ;
        import std.exception : enforce;

        // If the requested size exceeds available space in current arena,
        // create new arena
        size_t goodSize = goodAllocSize(n);
        if (currentArena.offset - currentArena.data > numPages * pageSize - goodSize)
            createArena();

        void* result = currentArena.offset;
        currentArena.offset += goodSize;
        currentArena.pagesUsed += goodSize / pageSize;

        // Give memory back just by changing page protection
        auto ret = mprotect(result, goodSize, PROT_WRITE | PROT_READ);
        enforce(ret == 0, "Failed to allocate memory, mprotect failure"); 

        return cast(void[]) result[0 .. n];
    }

    size_t goodAllocSize(size_t n)
    {
        if (n >= allocLimit)
            return n.roundUpToMultipleOf(pageSize);

        //TODO
        return n;
    }

    void[] allocate(size_t n)
    {
        if (n >= allocLimit)
            return allocateLarge(n);

        return allocateSmall(n);
    }

    // Naive algorithm to find the arena where a buffer lies
    private ArenaNode* findArena(void* buf)
    {
        ArenaNode *tmp = headArena;

        do
        {
            if (buf >= tmp.data && buf <= tmp.data + pageSize * numPages)
                return tmp;
            tmp = tmp.next;
        } while(tmp != headArena);

        return null;
    }

    private bool deallocateLarge(void[] buf)
    {
        //import core.sys.posix.sys.mman : madvise, MADV_DONTNEED, mprotect, PROT_NONE;
        import core.sys.posix.sys.mman : munmap, mprotect, PROT_NONE;
        import std.exception : enforce;

        size_t goodSize = goodAllocSize(buf.length);
        auto ret = mprotect(buf.ptr, goodSize, PROT_NONE);
        enforce(ret == 0, "Failed to deallocate memory, mprotect failure"); 

        // We might need madvise to let the OS reclaim the resources
        //ret = madvise(buf.ptr, goodSize, MADV_DONTNEED); 
        //enforce(ret == 0, "Failed to deallocate, madvise failure");

        // Find the arena which the pointer belongs to
        ArenaNode* arena = findArena(buf.ptr);
        arena.pagesUsed -= goodSize / pageSize;

        // unmap the arena if we don't use it anymore and it doesn't hold any alive objects
        if (!arena.valid && arena.pagesUsed == 0)
        {
            arena.next.prev = arena.prev;
            arena.prev.next = arena.next;
            if (arena == headArena)
                headArena = arena.next;
            munmap(arena.data, numPages * pageSize);
            parent.deallocate(arena[0 .. ArenaNode.sizeof]);
        }

        return true;
    }

    private bool deallocateSmall(void[] buf)
    {
        //TODO
        return true;
    }

    bool deallocate(void[] buf)
    {
        if (buf.length >= allocLimit)
            return deallocateLarge(buf);

        return deallocateSmall(buf);
    }
}

void main()
{
    size_t pages = 4;
    // Allocator has 4page arena size
    AscendingAllocator!NullAllocator a = AscendingAllocator!NullAllocator(pages);

    // b1, b2, b3, b4 should each occupy one page
    // test for each one if we can write/read without SIGSEGV
    void[] b1 = a.allocate(4091);
    *(cast(int*) b1.ptr) = 1;
    assert(*(cast(int*) b1.ptr) == 1);

    void[] b2 = a.allocate(4092);
    *(cast(int*) b2.ptr) = 2;
    assert(*(cast(int*) b2.ptr) == 2);

    void[] b3 = a.allocate(4093);
    *(cast(int*) b3.ptr) = 3;
    assert(*(cast(int*) b3.ptr) == 3);

    void[] b4 = a.allocate(4094);
    *(cast(int*) b4.ptr) = 4;
    assert(*(cast(int*) b4.ptr) == 4);

    assert(b1.length == 4091);
    assert(b2.length == 4092);
    assert(b3.length == 4093);
    assert(b4.length == 4094);

    // Check that the buffers are 1 page apart
    assert(b1.ptr + 4096 == b2.ptr);
    assert(b2.ptr + 4096 == b3.ptr);
    assert(b3.ptr + 4096 == b4.ptr);

    // New allocation should create a new arena
    void[] b5 = a.allocate(4097);
    assert(b5.length == 4097);
    assert(a.currentArena != a.headArena);

    // Deallocate everything on the first arena and check that the arena
    // is unmapped
    a.deallocate(b1);
    a.deallocate(b2);
    a.deallocate(b3);
    a.deallocate(b4);
    assert(a.currentArena == a.headArena);
}
