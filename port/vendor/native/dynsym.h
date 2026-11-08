/*
 * Look up a function of a library already loaded in the process, for code added to a binary
 * that does not import it (the added segment cannot get new imports: it has no relocations).
 * Walks the loaded objects with dl_iterate_phdr() (which the binary must import) and searches
 * the object's dynamic symbol table through its GNU or SysV hash table, as the dynamic linker
 * does. On Android the .dynamic entries hold unrelocated addresses: base + d_ptr.
 *
 * Nothing is cached (the segment has no writable data): one lookup costs a few microseconds,
 * so use it only on paths that run seldom (a key press, not a frame).
 */
#ifndef ROMBICA_NATIVE_DYNSYM_H
#define ROMBICA_NATIVE_DYNSYM_H

typedef unsigned int Elf32_Addr;
typedef unsigned int Elf32_Word;
typedef int Elf32_Sword;
typedef unsigned short Elf32_Half;

typedef struct {
	Elf32_Word p_type, p_offset;
	Elf32_Addr p_vaddr, p_paddr;
	Elf32_Word p_filesz, p_memsz, p_flags, p_align;
} Elf32_Phdr;

typedef struct {
	Elf32_Sword d_tag;
	Elf32_Word d_val;
} Elf32_Dyn;

typedef struct {
	Elf32_Word st_name;
	Elf32_Addr st_value;
	Elf32_Word st_size;
	unsigned char st_info, st_other;
	Elf32_Half st_shndx;
} Elf32_Sym;

struct dl_phdr_info {
	Elf32_Addr dlpi_addr;
	const char *dlpi_name;
	const Elf32_Phdr *dlpi_phdr;
	Elf32_Half dlpi_phnum;
};

int dl_iterate_phdr(int (*cb)(struct dl_phdr_info *info, size_t size, void *data), void *data);

#define PT_DYNAMIC 2
#define DT_NULL 0
#define DT_HASH 4
#define DT_STRTAB 5
#define DT_SYMTAB 6
#define DT_GNU_HASH 0x6ffffef5
#define SHN_UNDEF 0

struct dynsym_query {
	const char *lib;		/* file name, e.g. "libc.so" */
	const char *name;		/* symbol */
	void *addr;			/* result */
};

static int str_eq(const char *a, const char *b)
{
	while (*a && *a == *b)
		a++, b++;
	return *a == *b;
}

/* path ends with "/<file>" (or is <file>) */
static int is_lib(const char *path, const char *file)
{
	const char *base = path;

	for (; *path; path++)
		if (*path == '/')
			base = path + 1;
	return str_eq(base, file);
}

static unsigned int gnu_hash(const char *s)
{
	unsigned int h = 5381;

	while (*s)
		h = h * 33 + (unsigned char)*s++;
	return h;
}

static unsigned int sysv_hash(const char *s)
{
	unsigned int h = 0, g;

	while (*s) {
		h = (h << 4) + (unsigned char)*s++;
		g = h & 0xf0000000;
		h ^= g >> 24;
		h &= ~g;
	}
	return h;
}

static const Elf32_Sym *find_sym(const Elf32_Sym *symtab, const char *strtab,
				 const unsigned int *gnu, const unsigned int *sysv, const char *name)
{
	unsigned int i, h;

	if (gnu) {
		unsigned int nbuckets = gnu[0], symoffset = gnu[1], bloom_size = gnu[2];
		const unsigned int *buckets = gnu + 4 + bloom_size;
		const unsigned int *chain = buckets + nbuckets;

		h = gnu_hash(name);
		i = buckets[h % nbuckets];
		if (i < symoffset)
			return 0;
		for (;; i++) {
			unsigned int h2 = chain[i - symoffset];

			if ((h | 1) == (h2 | 1) && str_eq(name, strtab + symtab[i].st_name))
				return &symtab[i];
			if (h2 & 1)
				return 0;
		}
	}
	if (sysv) {
		unsigned int nbucket = sysv[0];
		const unsigned int *bucket = sysv + 2, *chain = bucket + nbucket;

		for (i = bucket[sysv_hash(name) % nbucket]; i; i = chain[i])
			if (str_eq(name, strtab + symtab[i].st_name))
				return &symtab[i];
	}
	return 0;
}

static int dynsym_cb(struct dl_phdr_info *info, size_t size, void *data)
{
	struct dynsym_query *q = data;
	const Elf32_Dyn *dyn = 0;
	const Elf32_Sym *symtab = 0, *sym;
	const char *strtab = 0;
	const unsigned int *gnu = 0, *sysv = 0;
	int i;

	if (!info->dlpi_name || !is_lib(info->dlpi_name, q->lib))
		return 0;
	for (i = 0; i < info->dlpi_phnum; i++)
		if (info->dlpi_phdr[i].p_type == PT_DYNAMIC)
			dyn = (const Elf32_Dyn *)(info->dlpi_addr + info->dlpi_phdr[i].p_vaddr);
	for (; dyn && dyn->d_tag != DT_NULL; dyn++) {
		const void *p = (const void *)(info->dlpi_addr + dyn->d_val);

		switch (dyn->d_tag) {
		case DT_SYMTAB:
			symtab = p;
			break;
		case DT_STRTAB:
			strtab = p;
			break;
		case DT_GNU_HASH:
			gnu = p;
			break;
		case DT_HASH:
			sysv = p;
			break;
		}
	}
	if (!symtab || !strtab)
		return 1;
	sym = find_sym(symtab, strtab, gnu, sysv, q->name);
	if (sym && sym->st_shndx != SHN_UNDEF)
		q->addr = (void *)(info->dlpi_addr + sym->st_value);
	return 1;				/* found the library: stop */
}

/* address of <name> in the loaded library <lib> (file name), or 0 */
static void *dynsym(const char *lib, const char *name)
{
	struct dynsym_query q = { lib, name, 0 };

	dl_iterate_phdr(dynsym_cb, &q);
	return q.addr;
}

#endif
