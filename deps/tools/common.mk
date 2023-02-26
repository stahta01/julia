## Some shared configuration options ##

# NOTE: Do not make RPATH changes in CMAKE_COMMON on platforms other than FreeBSD, since
# it will make its way into the LLVM build flags, and LLVM is picky about RPATH (though
# apparently not on FreeBSD). Ref PR #22352

CONFIGURE_COMMON = --prefix=$(abspath $(build_prefix)) --build=$(BUILD_MACHINE) --libdir=$(abspath $(build_libdir)) --bindir=$(abspath $(build_depsbindir)) $(CUSTOM_LD_LIBRARY_PATH)
ifneq ($(XC_HOST),)
CONFIGURE_COMMON += --host=$(XC_HOST)
endif
ifeq ($(OS),WINNT)
CONFIGURE_COMMON += LDFLAGS="$(LDFLAGS) -Wl,--stack,8388608"
else
CONFIGURE_COMMON += LDFLAGS="$(LDFLAGS) $(RPATH_ESCAPED_ORIGIN) $(SANITIZE_LDFLAGS)"
endif
CONFIGURE_COMMON += F77="$(FC)" CC="$(CC) $(SANITIZE_OPTS)" CXX="$(CXX) $(SANITIZE_OPTS)" LD="$(LD)"

CMAKE_CC_ARG := $(CC_ARG)
CMAKE_CXX_ARG := $(CXX_ARG)

CMAKE_COMMON := -DCMAKE_INSTALL_PREFIX:PATH=$(build_prefix) -DCMAKE_PREFIX_PATH=$(build_prefix)
CMAKE_COMMON += -DLIB_INSTALL_DIR=$(build_shlibdir)
ifeq ($(OS), Darwin)
CMAKE_COMMON += -DCMAKE_MACOSX_RPATH=1
endif

ifneq ($(VERBOSE), 0)
CMAKE_COMMON += -DCMAKE_VERBOSE_MAKEFILE=ON
endif
ifeq ($(BUILD_OS),WINNT)
CMAKE_COMMON += -DCMAKE_C_COMPILER="$$(cygpath -m $$(which $(CC_BASE)))"
else
# The call to which here is to work around https://cmake.org/Bug/view.php?id=14366
CMAKE_COMMON += -DCMAKE_C_COMPILER="$$(which $(CC_BASE))"
endif
ifneq ($(strip $(CMAKE_CC_ARG)),)
CMAKE_COMMON += -DCMAKE_C_COMPILER_ARG1="$(CMAKE_CC_ARG) $(SANITIZE_OPTS)"
endif
CMAKE_COMMON += -DCMAKE_CXX_COMPILER="$(CXX_BASE)"
ifneq ($(strip $(CMAKE_CXX_ARG)),)
CMAKE_COMMON += -DCMAKE_CXX_COMPILER_ARG1="$(CMAKE_CXX_ARG) $(SANITIZE_OPTS)"
endif
CMAKE_COMMON += -DCMAKE_LINKER="$$(which $(LD))" -DCMAKE_AR="$$(which $(AR))" -DCMAKE_RANLIB="$$(which $(RANLIB))"

ifeq ($(OS),WINNT)
CMAKE_COMMON += -DCMAKE_SYSTEM_NAME=Windows
CMAKE_COMMON += -DCMAKE_RC_COMPILER="$$(which $(CROSS_COMPILE)windres)"
endif

# For now this is LLVM specific, but I expect it won't be in the future
ifeq ($(CMAKE_GENERATOR),Ninja)
CMAKE_GENERATOR_COMMAND := -G Ninja
else ifeq ($(CMAKE_GENERATOR),make)
CMAKE_GENERATOR_COMMAND := -G "Unix Makefiles"
else
$(error Unknown CMake generator '$(CMAKE_GENERATOR)'. Options are 'Ninja' and 'make')
endif

# If the top-level Makefile is called with environment variables,
# they will override the values passed above to ./configure
MAKE_COMMON := DESTDIR="" prefix=$(build_prefix) bindir=$(build_depsbindir) libdir=$(build_libdir) shlibdir=$(build_shlibdir) libexecdir=$(build_libexecdir) datarootdir=$(build_datarootdir) includedir=$(build_includedir) sysconfdir=$(build_sysconfdir) O=

#Platform specific flags

ifeq ($(OS), WINNT)
LIBTOOL_CCLD := CCLD="$(CC) -no-undefined -avoid-version"
endif

# Cross-deps flags

USE_BLAS_FFLAGS :=
ifeq ($(USE_BLAS64), 1)
ifeq ($(USEIFC),1)
USE_BLAS_FFLAGS += -i8
else
USE_BLAS_FFLAGS += -fdefault-integer-8
endif
endif

ifeq ($(USE_INTEL_MKL),1)
# We want to test if gfortran is used but currently only gfortran and ifort are supported
# so not ifort is the same as gfortran. If support for new Fortran compilers is added
# then this should be adjusted
ifneq ($(USEIFC),1)
USE_BLAS_FFLAGS += -ff2c
endif
endif

ifeq ($(OS),Darwin)
ifeq ($(USE_SYSTEM_BLAS),1)
ifeq ($(USE_SYSTEM_LAPACK),0)
USE_BLAS_FFLAGS += -cpp -ffree-line-length-0 -ffixed-line-length-0 \
                   -Dsasum=sasum_gfort -Dscasum=scasum_gfort \
                   -Dscnrm2=scnrm2_gfort -Dsdot=sdot_gfort \
                   -Dsdsdot=sdsdot_gfort -Dsnrm2=snrm2_gfort \
                   -Dcdotc=cdotc_gfort -Dcdotu=cdotu_gfort \
                   -Dzdotc=zdotc_gfort -Dzdotu=zdotu_gfort \
                   \
                   -DSASUM=SASUM_GFORT -DSCASUM=SCASUM_GFORT \
                   -DSCNRM2=SCNRM2_GFORT -DSDOT=SDOT_GFORT \
                   -DSDSDOT=SDSDOT_GFORT -DSNRM2=SNRM2_GFORT \
                   -DCDOTC=CDOTC_GFORT -DCDOTU=CDOTU_GFORT \
                   -DZDOTC=ZDOTC_GFORT -DZDOTU=ZDOTU_GFORT
endif
endif
endif


## PATHS ##
# sort is used to remove potential duplicates
DIRS := $(sort $(build_bindir) $(build_depsbindir) $(build_libdir) $(build_includedir) $(build_sysconfdir) $(build_datarootdir) $(build_staging) $(build_prefix)/manifest)

$(foreach dir,$(DIRS),$(eval $(call dir_target,$(dir))))

$(build_prefix): | $(DIRS)
$(eval $(call dir_target,$(SRCCACHE)))


upper = $(shell echo $1 | tr a-z A-Z)


## A rule for calling `make install` ##
# example usage:
#   $(call staged-install, \
#       1 target, \               # name
#       2 rel-build-directory, \  # BUILDDIR-relative path to binaries
#       3 MAKE_INSTALL, \         # will be called with args SRCDIR,DESTDIR,$4
#       4 add-args, \             # extra args for $3
#       5 (unused), \
#       6 post-install)           # post-install commands
#
# this rule ensures that make install is more nearly atomic
# so it's harder to get half-installed (or half-reinstalled) dependencies
# # and enables sharing deps compiles, uninstall, and fast reinstall
MAKE_INSTALL = +$$(MAKE) -C $1 install $$(MAKE_COMMON) $3 DESTDIR="$2"

define SHLIBFILE_INSTALL
	mkdir -p $2/$$(build_shlibdir)
	cp $3 $2/$$(build_shlibdir)
endef

define BINFILE_INSTALL
	mkdir -p $2/$$(build_depsbindir)
	cp $3 $2/$$(build_depsbindir)
endef

define staged-install
stage-$(strip $1): $$(build_staging)/$2.tar
install-$(strip $1): $$(build_prefix)/manifest/$(strip $1)

ifeq (exists, $$(shell [ -e $$(build_staging)/$2.tar ] && echo exists ))
# clean depends on uninstall only if the staged file exists
distclean-$(strip $1) clean-$(strip $1): uninstall-$(strip $1)
else
# uninstall depends on staging only if the staged file doesn't exist
# otherwise, uninstall doesn't actually want the file to be updated first
uninstall-$(strip $1): | $$(build_staging)/$2.tar
endif

reinstall-$(strip $1):
	+$$(MAKE) uninstall-$(strip $1)
	-rm -f $$(build_staging)/$2.tar
	+$$(MAKE) stage-$(strip $1)
	+$$(MAKE) install-$(strip $1)

$$(build_staging)/$2.tar: $$(BUILDDIR)/$2/build-compiled
	rm -rf $$(build_staging)/$2
	mkdir -p $$(build_staging)/$2$$(build_prefix)
	$(call $3,$$(BUILDDIR)/$2,$$(build_staging)/$2,$4)
	cd $$(build_staging)/$2$$(build_prefix) && $$(TAR) -cf $$@.tmp .
	rm -rf $$(build_staging)/$2
	mv $$@.tmp $$@

UNINSTALL_$(strip $1) := $2 staged-uninstaller

$$(build_prefix)/manifest/$(strip $1): $$(build_staging)/$2.tar | $(build_prefix)/manifest
	-+[ ! -e $$@ ] || $$(MAKE) uninstall-$(strip $1)
	$(UNTAR) $$< -C $$(build_prefix)
	$6
	echo '$$(UNINSTALL_$(strip $1))' > $$@
endef

define staged-uninstaller
uninstall-$(strip $1):
	-cd $$(build_prefix) && rm -fv -- $$$$($$(TAR) -tf $$(build_staging)/$2.tar | grep -v '/$$$$')
	-rm -f $$(build_prefix)/manifest/$(strip $1)
endef


## A rule for "installing" via a symlink ##
# example usage:
#   $(call symlink_install, \
#       1 target, \               # name
#       2 rel-build-directory, \  # BUILDDIR-relative path to content folder
#       3 abs-target-directory)   # absolute path to installation folder for symlink `name`
define symlink_install # (target-name, rel-from, abs-to)
clean-$1: uninstall-$1
install-$1: $$(build_prefix)/manifest/$1
reinstall-$1: install-$1

UNINSTALL_$(strip $1) := $2 symlink-uninstaller $3

$$(build_prefix)/manifest/$1: $$(BUILDDIR)/$2/build-compiled | $3 $$(build_prefix)/manifest
	-+[ ! \( -e $3/$1 -o -h $3/$1 \) ] || $$(MAKE) uninstall-$1
ifeq ($$(BUILD_OS), WINNT)
	cmd //C mklink //J $$(call mingw_to_dos,$3/$1,cd $3 &&) $$(call mingw_to_dos,$$(BUILDDIR)/$2,)
else ifneq (,$$(findstring CYGWIN,$$(BUILD_OS)))
	cmd /C mklink /J $$(call cygpath_w,$3/$1) $$(call cygpath_w,$$(BUILDDIR)/$2)
else ifdef JULIA_VAGRANT_BUILD
	cp -R $$(BUILDDIR)/$2 $3/$1
else
	ln -sf $$(abspath $$(BUILDDIR)/$2) $3/$1
endif
	echo '$$(UNINSTALL_$(strip $1))' > $$@
endef

define symlink-uninstaller
uninstall-$1:
ifeq ($$(BUILD_OS), WINNT)
	-cmd //C rmdir $$(call mingw_to_dos,$3/$1,cd $3 &&)
else
	rm -rf $3/$1
endif
	-rm -f $$(build_prefix)/manifest/$1
endef


ifneq (bsdtar,$(findstring bsdtar,$(TAR_TEST)))
#gnu tar
UNTAR = $(TAR) -xmf
else
#bsd tar
UNTAR = $(TAR) -xmUf
endif


## phony targets ##

.PHONY: default get extract configure compile fastcheck check install uninstall reinstall cleanall distcleanall version-check \
	get-* extract-* configure-* compile-* fastcheck-* check-* install-* uninstall-* reinstall-* clean-* distclean-* \
	update-llvm
