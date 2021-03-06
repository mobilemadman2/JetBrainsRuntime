[![official JetBrains project](http://jb.gg/badges/official.svg)](https://confluence.jetbrains.com/display/ALL/JetBrains+on+GitHub)

# Downloads

|Windows-x64  |macOS        |Linux-x64    |
|-------------|-------------|-------------|
|<a href="https://bintray.com/jetbrains/intellij-jdk/openjdk9-windows-x64/_latestVersion"> <img src="https://api.bintray.com/packages/jetbrains/intellij-jdk/openjdk9-windows-x64/images/download.svg"/></a>|<a href="https://bintray.com/jetbrains/intellij-jdk/openjdk9-osx-x64/_latestVersion"> <img src="https://api.bintray.com/packages/jetbrains/intellij-jdk/openjdk9-osx-x64/images/download.svg"/></a>|<a href="https://bintray.com/jetbrains/intellij-jdk/openjdk9-linux-x64/_latestVersion"><img src="https://api.bintray.com/packages/jetbrains/intellij-jdk/openjdk9-linux-x64/images/download.svg"/></a>|


# How JetBrains Runtime is organised
## Workspaces

[github.com/JetBrains/JetBrainsRuntime](https://github.com/JetBrains/JetBrainsRuntime)  

## Getting sources
__OSX, Linux:__
```
git config --global core.autocrlf input
git clone git@github.com:JetBrains/JetBrainsRuntime.git
```

__Windows:__
```
git config --global core.autocrlf false
git clone git@github.com:JetBrains/JetBrainsRuntime.git
```

# Configure Local Build Environment
[OpenJDK build docs](http://hg.openjdk.java.net/jdk/jdk11/raw-file/tip/doc/building.html)  
Tip for all platforms: run ./configure and check output.  
Usually, it has meaningful advice how to solve your problem.

## Linux (docker)
```
$ cd jb/project/docker
$ docker build .
...
Successfully built 942ea9900054

$ docker run -v `pwd`../../../../:/JetBrainsRuntime -it 942ea9900054

# cd /JetBrainsRuntime
# sh ./configure
# make images CONF=linux-x86_64-normal-server-release

```

## Linux (Ubuntu 18.10 desktop)
```
$ sudo apt-get install autoconf make build-essential libx11-dev libxext-dev libxrender-dev libxtst-dev libxt-dev libxrandr-dev libcups2-dev libfontconfig1-dev libasound2-dev 

$ cd JetBrainsRuntime
$ sh ./configure --disable-warnings-as-errors
$ make images
```

## Windows
Install:

* [Cygwin x64](http://www.cygwin.com/)  
  Required packages: autoconf, binutils, cpio, diffutils, file, gawk, gcc-core, make, m4, unzip, zip.  
  **Install them while installing cygwin**.
* Visual Studio compiler toolset [Download](https://visualstudio.microsoft.com/downloads/)  
  Visual Studio 2015 has support by default.  
  **Install with desktop development kit, it includes Windows SDK and compilers**.
* [Java 11](http://www.oracle.com/technetwork/java/javase/downloads/index.html)  
  If you have problems while configuring [read java tips on cygwin](http://horstmann.com/articles/cygwin-tips.html)

From command line 
```
"c:\Program Files (x86)\Microsoft Visual Studio 14.0\VC\vcvarsall.bat" amd64
"c:\Program_Files\cygwin64\bin\mintty.exe" /bin/bash -l
```
First command will set env vars, the second will run cygwin shell with proper environment.  
In cygwin shell 
```    
cd JetBrainsRuntime
./configure --disable-warnings-as-errors
make images
```

## OSX

install Xcode console tools, autoconf (via homebrew)

run

```
sh ./configure --prefix=$(pwd)/build  --disable-warnings-as-errors
make images
```

## Contribution
We will be happy to receive your pull requests. Before you submit one, please sign our Contributor License Agreement (CLA)  https://www.jetbrains.com/agreements/cla/ 
