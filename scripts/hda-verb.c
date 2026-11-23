/* Minimal hda-verb for HD-audio hwdep device (no alsa-tools needed) */
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/ioctl.h>

struct hda_verb_ioctl {
	uint32_t verb;
	uint32_t res;
};

#define HDA_IOCTL_PVERSION	_IOR('H', 0x10, int)
#define HDA_IOCTL_VERB_WRITE	_IOWR('H', 0x11, struct hda_verb_ioctl)
#define HDA_VERB(nid, verb, param) \
	((uint32_t)(nid) << 24 | (uint32_t)(verb) << 8 | (uint32_t)(param))

int main(int argc, char **argv)
{
	struct hda_verb_ioctl val;
	int fd, ver = 0;
	unsigned int nid, verb, param;

	if (argc != 5) {
		fprintf(stderr, "usage: %s <hwdep-device> <nid> <verb> <param>\n", argv[0]);
		return 1;
	}
	nid = strtoul(argv[2], NULL, 0);
	verb = strtoul(argv[3], NULL, 0);
	param = strtoul(argv[4], NULL, 0);

	fd = open(argv[1], O_RDWR);
	if (fd < 0) {
		perror("open");
		return 1;
	}
	if (ioctl(fd, HDA_IOCTL_PVERSION, &ver) < 0) {
		perror("ioctl(PVERSION)");
		close(fd);
		return 1;
	}
	if (ver < 0x10000) {
		fprintf(stderr, "unexpected hwdep version 0x%x\n", ver);
		close(fd);
		return 1;
	}

	val.verb = HDA_VERB(nid, verb, param);
	val.res = 0;
	if (ioctl(fd, HDA_IOCTL_VERB_WRITE, &val) < 0) {
		perror("ioctl(VERB_WRITE)");
		close(fd);
		return 1;
	}
	printf("0x%x\n", val.res);
	close(fd);
	return 0;
}
