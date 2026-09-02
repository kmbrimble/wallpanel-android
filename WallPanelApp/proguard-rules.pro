# Add project specific ProGuard rules here.
# By default, the flags in this file are appended to flags specified
# in C:\Users\raimund\AppData\Local\Android\sdk/tools/proguard/proguard-android.txt
# You can edit the include path and order by changing the proguardFiles
# directive in build.gradle.
#
# For more details, see
#   http://developer.android.com/guide/developing/tools/proguard.html

# Add any project specific keep options here:

# Dagger
-keep class dagger.** { *; }
-keep class javax.inject.** { *; }
-keep class *_Factory { *; }
-keep class *_MembersInjector { *; }

# Generic signature/annotation retention. Previously filed under a "Gson / Retrofit"
# heading, but Gson, Retrofit and OkHttp are gone and these are not theirs - Hilt and
# Dagger need both to resolve generic bindings and read @Inject/@Module. Keep.
-keepattributes Signature
-keepattributes *Annotation*

# HiveMQ / Netty (already below)
-keepattributes SourceFile,LineNumberTable
-keep public class * extends java.lang.Exception

# Glide
-keep public class * implements com.bumptech.glide.module.GlideModule
-keep class * extends com.bumptech.glide.module.AppGlideModule { <init>(...); }
-keep public enum com.bumptech.glide.load.ImageHeaderParser$** { *; }
-keep class com.bumptech.glide.load.data.ParcelFileDescriptorRewinder$InternalRewinder { *; }

# If your project uses WebView with JS, uncomment the following
# and specify the fully qualified class name to the JavaScript interface
# class:
#-keepclassmembers class fqcn.of.javascript.interface.for.webview {
#   public *;
#}

-keepclassmembernames class io.netty.** { *; }
-keepclassmembers class org.jctools.** { *; }