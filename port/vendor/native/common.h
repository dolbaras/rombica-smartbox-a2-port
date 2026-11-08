/*
 * Shared helpers for the code added to SlimBOX binaries (built freestanding: no libc headers,
 * the library's own imports are called through its PLT, see plt_symbols.py and build.sh).
 * Everything here is static inline or static: the added segment has no relocations and no
 * writable data.
 */
#ifndef ROMBICA_NATIVE_COMMON_H
#define ROMBICA_NATIVE_COMMON_H

typedef unsigned int size_t;
typedef int ssize_t;

#define PROP_VALUE_MAX 92
#define O_RDONLY 0
#define ANDROID_LOG_INFO 4

/* imports of the patched binary */
int property_get(const char *key, char *value, const char *default_value);
int property_set(const char *key, const char *value);
int open(const char *path, int flags, ...);
ssize_t read(int fd, void *buf, size_t count);
int close(int fd);
int atoi(const char *s);
int strncmp(const char *a, const char *b, size_t n);
int __android_log_print(int prio, const char *tag, const char *fmt, ...);

/* read a small text file, NUL-terminated; returns its length or -1 */
static int read_file(const char *path, char *buf, int size)
{
	int fd = open(path, O_RDONLY), n = -1, r;

	if (fd < 0)
		return -1;
	for (n = 0; n < size - 1; n += r) {
		r = read(fd, buf + n, size - 1 - n);
		if (r <= 0)
			break;
	}
	close(fd);
	buf[n] = 0;
	return n;
}

static int is_digit(char c)
{
	return c >= '0' && c <= '9';
}

/* "<w>x<h>" at the start of s (followed by anything); 0 on success */
static int parse_size(const char *s, unsigned *w, unsigned *h)
{
	unsigned a = 0, b = 0;

	if (!is_digit(*s))
		return -1;
	while (is_digit(*s))
		a = a * 10 + (*s++ - '0');
	if (*s++ != 'x' || !is_digit(*s))
		return -1;
	while (is_digit(*s))
		b = b * 10 + (*s++ - '0');
	if (!a || !b)
		return -1;
	*w = a;
	*h = b;
	return 0;
}

/* a VESA mode name "<w>x<h>p<rate>hz"; 0 on success */
static int parse_vesa(const char *s, unsigned *w, unsigned *h)
{
	if (parse_size(s, w, h))
		return -1;
	while (*s != 'x')
		s++;
	s++;
	while (is_digit(*s))
		s++;
	return *s == 'p' ? 0 : -1;
}

/* the line of disp_cap marked '*' (the sink's native mode), or 0; the line ends at '*' */
static const char *native_mode(const char *cap)
{
	const char *line = cap, *p;

	for (p = cap; *p; p++) {
		if (*p == '\n')
			line = p + 1;
		else if (*p == '*')
			return line;
	}
	return 0;
}

static void utoa(unsigned v, char *s)
{
	char t[12];
	int i = 0;

	do
		t[i++] = '0' + v % 10;
	while (v /= 10);
	while (i)
		*s++ = t[--i];
	*s = 0;
}

#endif
