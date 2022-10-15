#import "libPwnify.h"

#define ALIGN_DEFAULT 0xE

uint32_t roundUp(int numToRound, int multiple)
{
	if (multiple == 0)
		return numToRound;

	int remainder = numToRound % multiple;
	if (remainder == 0)
		return numToRound;

	return numToRound + multiple - remainder;
}

void expandFile(FILE* file, uint32_t size)
{
	fseek(file, 0, SEEK_END);
	if(ftell(file) >= size) return;
	
	while(ftell(file) != size)
	{
		char c = 0;
		fwrite(&c, 1, 1, file);
	}
}

void copyData(FILE* sourceFile, FILE* targetFile, size_t size)
{
	for(size_t i = 0; i < size; i++)
	{
		char b;
		fread(&b, 1, 1, sourceFile);
		fwrite(&b, 1, 1, targetFile);
	}
}

void pwnify_enumerateArchs(NSString* binaryPath, void (^archEnumBlock)(struct fat_arch* arch, uint32_t archFileOffset, struct mach_header* machHeader, uint32_t sliceFileOffset, FILE* file, BOOL* stop))
{
	FILE* machoFile = fopen(binaryPath.UTF8String, "rb");
	if(!machoFile) return;
	
	struct mach_header header;
	fread(&header,sizeof(header),1,machoFile);
	
	if(header.magic == FAT_MAGIC || header.magic == FAT_CIGAM)
	{
		fseek(machoFile,0,SEEK_SET);
		struct fat_header fatHeader;
		fread(&fatHeader,sizeof(fatHeader),1,machoFile);
		
		for(int i = 0; i < OSSwapBigToHostInt32(fatHeader.nfat_arch); i++)
		{
			uint32_t archFileOffset = sizeof(fatHeader) + sizeof(struct fat_arch) * i;
			struct fat_arch fatArch;
			fseek(machoFile, archFileOffset,SEEK_SET);
			fread(&fatArch,sizeof(fatArch),1,machoFile);
			
			uint32_t sliceFileOffset = OSSwapBigToHostInt32(fatArch.offset);
			struct mach_header archHeader;
			fseek(machoFile, sliceFileOffset, SEEK_SET);
			fread(&archHeader,sizeof(archHeader),1,machoFile);
			
			BOOL stop = NO;
			archEnumBlock(&fatArch, archFileOffset, &archHeader, sliceFileOffset, machoFile, &stop);
			if(stop) break;
		}
	}
	else if(header.magic == MH_MAGIC_64 || header.magic == MH_CIGAM_64)
	{
		BOOL stop;
		archEnumBlock(NULL, 0, &header, 0, machoFile, &stop);
	}
	
	fclose(machoFile);
}

void pwnify_setCPUSubtype(NSString* binaryPath, uint32_t subtype)
{
	FILE* binaryFile = fopen(binaryPath.UTF8String, "rb+");
	if(!binaryFile)
	{
		printf("ERROR: File not found\n");
		return;
	}
	
	pwnify_enumerateArchs(binaryPath, ^(struct fat_arch *arch, uint32_t archFileOffset, struct mach_header *machHeader, uint32_t sliceFileOffset, FILE *file, BOOL *stop) {
		
		if(arch)
		{
			if(OSSwapBigToHostInt(arch->cputype) == 0x100000C)
			{
				if(OSSwapBigToHostInt(arch->cpusubtype) == 0x0)
				{
					arch->cpusubtype = OSSwapHostToBigInt32(subtype);
					fseek(binaryFile, archFileOffset, SEEK_SET);
					fwrite(arch, sizeof(struct fat_arch), 1, binaryFile);
				}
			}
		}
		
		if(OSSwapLittleToHostInt32(machHeader->cputype) == 0x100000C)
		{
			if(OSSwapLittleToHostInt32(machHeader->cpusubtype) == 0x0)
			{
				machHeader->cpusubtype = OSSwapHostToLittleInt32(subtype);
				fseek(binaryFile, sliceFileOffset, SEEK_SET);
				fwrite(machHeader, sizeof(struct mach_header), 1, binaryFile);
			}
		}
	});
	
	fclose(binaryFile);
}

void pwnify(NSString* appStoreBinary, NSString* binaryToInject, BOOL preferArm64e, BOOL replaceBinaryToInject)
{
	NSString* tmpFilePath = [NSTemporaryDirectory() stringByAppendingString:[[NSUUID UUID] UUIDString]];
	
	// Determine amount of slices in output
	__block int slicesCount = 1;
	pwnify_enumerateArchs(appStoreBinary, ^(struct fat_arch* arch, uint32_t archFileOffset, struct mach_header* machHeader, uint32_t sliceFileOffset, FILE* file, BOOL* stop) {
		slicesCount++;
	});
	
	// Allocate FAT data
	uint32_t fatDataSize = sizeof(struct fat_header) + slicesCount * sizeof(struct fat_arch);
	char* fatData = malloc(fatDataSize);

	// Construct new fat header
	struct fat_header fatHeader;
	fatHeader.magic = OSSwapHostToBigInt32(0xCAFEBABE);
	fatHeader.nfat_arch = OSSwapHostToBigInt32(slicesCount);
	memcpy(&fatData[0], &fatHeader, sizeof(fatHeader));
	
	uint32_t align = pow(2, ALIGN_DEFAULT);
	__block uint32_t curOffset = align;
	__block uint32_t curArchIndex = 0;

	// Construct new fat arch data
	pwnify_enumerateArchs(appStoreBinary, ^(struct fat_arch* arch, uint32_t archFileOffset, struct mach_header* machHeader, uint32_t sliceFileOffset, FILE* file, BOOL* stop) {
		struct fat_arch newArch;
		if(arch)
		{
			newArch.cputype = arch->cputype;
			
			if(OSSwapBigToHostInt32(arch->cputype) == 0x100000C)
			{
				newArch.cpusubtype = OSSwapHostToBigInt32(2); // SET app store binary in FAT header to 2, fixes arm64e
			}
			else
			{
				newArch.cpusubtype = arch->cpusubtype;
			}
			
			newArch.size = arch->size;
		}
		else
		{
			newArch.cputype = OSSwapHostToBigInt32(OSSwapLittleToHostInt32(machHeader->cputype));
			
			if(OSSwapLittleToHostInt32(machHeader->cputype) == 0x100000C)
			{
				newArch.cpusubtype = OSSwapHostToBigInt32(2); // SET app store binary in FAT header to 2, fixes arm64e
			}
			else
			{
				newArch.cpusubtype = OSSwapHostToBigInt32(OSSwapLittleToHostInt32(machHeader->cpusubtype));
			}
			
			newArch.size = OSSwapHostToBigInt32((uint32_t)[[[NSFileManager defaultManager] attributesOfItemAtPath:appStoreBinary error:nil] fileSize]);
		}
		
		newArch.align = OSSwapHostToBigInt32(ALIGN_DEFAULT);
		newArch.offset = OSSwapHostToBigInt32(curOffset);
		curOffset += roundUp(OSSwapBigToHostInt32(newArch.size), align);
		
		memcpy(&fatData[sizeof(fatHeader) + sizeof(struct fat_arch)*curArchIndex], &newArch, sizeof(newArch));
		curArchIndex++;
	});
	
	// Determine what slices our injection binary contains
	__block BOOL toInjectHasArm64e = NO;
	__block BOOL toInjectHasArm64 = NO;
	pwnify_enumerateArchs(binaryToInject, ^(struct fat_arch* arch, uint32_t archFileOffset, struct mach_header* machHeader, uint32_t sliceFileOffset, FILE* file, BOOL* stop) {
		if(arch)
		{
			if(OSSwapBigToHostInt32(arch->cputype) == 0x100000C)
			{
				if (!((OSSwapBigToHostInt32(arch->cpusubtype) ^ 0x2) & 0xFFFFFF))
				{
					toInjectHasArm64e = YES;
				}
				else if(!((OSSwapBigToHostInt32(arch->cpusubtype) ^ 0x1) & 0xFFFFFF))
				{
					toInjectHasArm64 = YES;
				}
			}
		}
		else
		{
			if(OSSwapLittleToHostInt32(machHeader->cputype) == 0x100000C)
			{
				if (!((OSSwapLittleToHostInt32(machHeader->cpusubtype) ^ 0x2) & 0xFFFFFF))
				{
					toInjectHasArm64e = YES;
				}
				else if(!((OSSwapLittleToHostInt32(machHeader->cpusubtype) ^ 0x1) & 0xFFFFFF))
				{
					toInjectHasArm64 = YES;
				}
			}
		}
	});
	
	if(!toInjectHasArm64 && !preferArm64e)
	{
		printf("ERROR: can't proceed injection because binary to inject has no arm64 slice\n");
		return;
	}
	
	uint32_t subtypeToUse = 0x1;
	if(preferArm64e && toInjectHasArm64e)
	{
		subtypeToUse = 0x2;
	}
	
	pwnify_enumerateArchs(binaryToInject, ^(struct fat_arch* arch, uint32_t archFileOffset, struct mach_header* machHeader, uint32_t sliceFileOffset, FILE* file, BOOL* stop) {
		struct fat_arch currentArch;
		if(arch)
		{
			currentArch.cputype = arch->cputype;
			currentArch.cpusubtype = arch->cpusubtype;
			currentArch.size = arch->size;
		}
		else
		{
			currentArch.cputype = OSSwapHostToBigInt(OSSwapLittleToHostInt32(machHeader->cputype));
			currentArch.cpusubtype = OSSwapHostToBigInt(OSSwapLittleToHostInt32(machHeader->cpusubtype));
			currentArch.size = OSSwapHostToBigInt((uint32_t)[[[NSFileManager defaultManager] attributesOfItemAtPath:binaryToInject error:nil] fileSize]);
		}

		if(OSSwapBigToHostInt32(currentArch.cputype) == 0x100000C)
		{
			if (!((OSSwapBigToHostInt32(currentArch.cpusubtype) ^ subtypeToUse) & 0xFFFFFF))
			{
				currentArch.align = OSSwapHostToBigInt32(ALIGN_DEFAULT);
				currentArch.offset = OSSwapHostToBigInt32(curOffset);
				curOffset += roundUp(OSSwapBigToHostInt32(currentArch.size), align);
				memcpy(&fatData[sizeof(fatHeader) + sizeof(struct fat_arch)*curArchIndex], &currentArch, sizeof(currentArch));
				curArchIndex++;
				*stop = YES;
			}
		}
	});
	
	// FAT Header constructed, now write to file and then write the slices themselves
	
	FILE* tmpFile = fopen(tmpFilePath.UTF8String, "wb");
	fwrite(&fatData[0], fatDataSize, 1, tmpFile);
	
	curArchIndex = 0;
	pwnify_enumerateArchs(appStoreBinary, ^(struct fat_arch* arch, uint32_t archFileOffset, struct mach_header* machHeader, uint32_t sliceFileOffset, FILE* file, BOOL* stop) {
		struct fat_arch* toWriteArch = (struct fat_arch*)&fatData[sizeof(fatHeader) + sizeof(struct fat_arch)*curArchIndex];
		
		expandFile(tmpFile, OSSwapBigToHostInt32(toWriteArch->offset));
		
		uint32_t offset = 0;
		uint32_t size = 0;
		
		if(arch)
		{
			offset = OSSwapBigToHostInt32(arch->offset);
			size = OSSwapBigToHostInt32(arch->size);
		}
		else
		{
			size = OSSwapBigToHostInt32(toWriteArch->size);
		}
		
		FILE* appStoreBinaryFile = fopen(appStoreBinary.UTF8String, "rb");
		fseek(appStoreBinaryFile, offset, SEEK_SET);
		copyData(appStoreBinaryFile, tmpFile, size);
		fclose(appStoreBinaryFile);
		curArchIndex++;
	});
	
	struct fat_arch* toWriteArch = (struct fat_arch*)&fatData[sizeof(fatHeader) + sizeof(struct fat_arch)*curArchIndex];
	pwnify_enumerateArchs(binaryToInject, ^(struct fat_arch* arch, uint32_t archFileOffset, struct mach_header* machHeader, uint32_t sliceFileOffset, FILE* file, BOOL* stop) {
		struct fat_arch currentArch;
		if(arch)
		{
			currentArch.cputype = arch->cputype;
			currentArch.cpusubtype = arch->cpusubtype;
			currentArch.size = arch->size;
		}
		else
		{
			currentArch.cputype = OSSwapHostToBigInt32(OSSwapLittleToHostInt32(machHeader->cputype));
			currentArch.cpusubtype = OSSwapHostToBigInt32(OSSwapLittleToHostInt32(machHeader->cpusubtype));
			currentArch.size = OSSwapHostToBigInt32((uint32_t)[[[NSFileManager defaultManager] attributesOfItemAtPath:binaryToInject error:nil] fileSize]);
		}

		if(OSSwapBigToHostInt32(currentArch.cputype) == 0x100000C)
		{
			if (!((OSSwapBigToHostInt32(currentArch.cpusubtype) ^ subtypeToUse) & 0xFFFFFF))
			{
				expandFile(tmpFile, OSSwapBigToHostInt32(toWriteArch->offset));
				
				uint32_t offset = 0;
				uint32_t size = 0;
				
				if(arch)
				{
					offset = OSSwapBigToHostInt32(arch->offset);
					size = OSSwapBigToHostInt32(arch->size);
				}
				else
				{
					size = OSSwapBigToHostInt32(toWriteArch->size);
				}
				
				FILE* binaryToInjectFile = fopen(binaryToInject.UTF8String, "rb");
				fseek(binaryToInjectFile, offset, SEEK_SET);
				copyData(binaryToInjectFile, tmpFile, size);
				fclose(binaryToInjectFile);
				*stop = YES;
			}
		}
	});
	
	fclose(tmpFile);
	chmod(tmpFilePath.UTF8String, 0755);

	if(replaceBinaryToInject)
	{
		[[NSFileManager defaultManager] removeItemAtPath:binaryToInject error:nil];
		[[NSFileManager defaultManager] moveItemAtPath:tmpFilePath toPath:binaryToInject error:nil];
	}
	else
	{
		[[NSFileManager defaultManager] removeItemAtPath:appStoreBinary error:nil];
		[[NSFileManager defaultManager] moveItemAtPath:tmpFilePath toPath:appStoreBinary error:nil];
	}
}

pwnify_state pwnifyGetBinaryState(NSString* binaryToCheck)
{
	__block BOOL has2To0Slice = NO;
	__block BOOL hasArmv8Slice = NO;
	__block BOOL hasArm64eNewAbiSlice = NO;

	pwnify_enumerateArchs(binaryToCheck, ^(struct fat_arch* arch, uint32_t archFileOffset, struct mach_header* machHeader, uint32_t sliceFileOffset, FILE* file, BOOL* stop)
	{
		if(arch && machHeader)
		{
			uint32_t mach_cputype = OSSwapLittleToHostInt32(machHeader->cputype);
			uint32_t fat_cputype = OSSwapBigToHostInt32(arch->cputype);
			uint32_t mach_cpusubtype = OSSwapLittleToHostInt32(machHeader->cpusubtype);
			uint32_t fat_cpusubtype = OSSwapBigToHostInt32(arch->cpusubtype);
			if(mach_cputype == 0x100000C && fat_cputype == 0x100000C)
			{
				if(fat_cpusubtype == 0x2 && mach_cpusubtype == 0x0)
				{
					has2To0Slice = YES;
				}
				else if(fat_cpusubtype == 0x1 && mach_cpusubtype == 0x1)
				{
					hasArmv8Slice = YES;
				}
				else if(fat_cpusubtype == 0x80000002 && mach_cpusubtype == 0x80000002)
				{
					hasArm64eNewAbiSlice = YES;
				}
			}
		}
	});

	pwnify_state outState = PWNIFY_STATE_NOT_PWNIFIED;
	if(has2To0Slice && hasArmv8Slice)
	{
		outState = PWNIFY_STATE_PWNIFIED_ARM64;
	}
	else if(has2To0Slice && hasArm64eNewAbiSlice)
	{
		outState = PWNIFY_STATE_PWNIFIED_ARM64E;
	}

	return outState;
}