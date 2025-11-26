# Phone_Build_Script for fxtec Pro1x  
  
Phone_Build_script. Shell script to build a distribution in chroot then create img files for your phone.  
  
Just edit the script --- include packages, kernel etc and test. Or use as a phone.  
  
Currently I am Using on Fxtec Pro1x. V_2 boots and seems to stabilize touch. I am using kernel 6.18-rc6 debian.  
  
V_2 will be about getting fluxbox working with onboard so i can debug. And booting better. 
  
Would be nice for PinePhone  
  
# V_2  
# Files  
  
patches/apply_patches.sh # test patches  
patches/display-regression-6.18-all-dtsi.patch # regulator/delay hack ... will fix  
patches/display-regression-6.18-all-dts.patch  
  
full_build_script-fluxbox-V2.sh # current build script  
MK_img-FINAL.sh # to make small adjustments  
flash.sh # flash img files  
MGL.config # current .config  
  
boot.img  
rootfs.img  
vbmeta.img # probably not needed  

Note: Boots black
  
# remove .Image.gz-dtb when done  
  
Let me know what you think!  

