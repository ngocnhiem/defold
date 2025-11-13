// Copyright 2020-2025 The Defold Foundation
// Copyright 2014-2020 King
// Copyright 2009-2014 Ragnar Svensson, Christian Murray
// Licensed under the Defold License version 1.0 (the "License"); you may not use
// this file except in compliance with the License.
//
// You may obtain a copy of the License, together with FAQs at
// https://www.defold.com/license
//
// Unless required by applicable law or agreed to in writing, software distributed
// under the License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR
// CONDITIONS OF ANY KIND, either express or implied. See the License for the
// specific language governing permissions and limitations under the License.

package com.dynamo.bob.fs;

import java.util.HashMap;

public class ResourceUtil {

    protected static HashMap<String, String> extensionMapping = new HashMap<>();
    protected static HashMap<String, String> cachedPaths = new HashMap<>();

    private static boolean minifyPathEnabled = false;
    private static HashMap<String, Integer> minifyCounters = new HashMap<>();

    protected static String buildDirectory = null;

    public static void registerMapping(String inExt, String outExt) {
        extensionMapping.put(inExt, outExt);
        minifyCounters.put(outExt, 0);
    }

    public static void setBuildDirectory(String buildDirectory) {
        ResourceUtil.buildDirectory = buildDirectory;
    }

    /**
     * Change extension of filename
     * @param fileName file-name to change extension for
     * @param ext new extension including preceding dot
     * @return new file-name
     */
    public static String changeExt(String fileName, String ext) {
        int i = fileName.lastIndexOf(".");
        if (i == -1) {
            throw new IllegalArgumentException(String.format("Missing extension in name '%s'", fileName));
        }
        fileName = fileName.substring(0, i);
        return fileName + ext;
    }

    /**
     * Optionally change suffix of filename if the requested input suffix matches
     * @param path path to change suffix for
     * @param from input suffix
     * @param to output suffix
     * @return modified path if input suffix matched, otherwise the original input path
     */
    public static String replaceExt(String path, String from, String to) {
        if (path.endsWith(from)) {
            return path.substring(0, path.lastIndexOf(from)).concat(to);
        }
        return path;
    }

   /**
    * Get the output suffix from an input siffix
    * @param inExt the input file suffix (including the '.')
    * @return the output suffix (including the '.')
    */
    public static String getOutputExt(String inExt) {
        String outExt = extensionMapping.get(inExt); // Get the output ext, or use the inExt as default
        if (outExt != null)
            return outExt;
        return inExt;
    }

    // returns suffix with ".suffix"
    public static String getSuffix(String path) {
        int index = path.lastIndexOf(".");
        if (index < 0)
            return null;
        return path.substring(index);
    }

    public static void enableMinification(boolean enable) {
        minifyPathEnabled = enable;
    }

    public static String minifyPathAndReplaceExt(String path, String from, String to) {
        path = replaceExt(path, from, to);
        return minifyPath(path);
    }

    public static void disableMinify(String ext) {
        minifyCounters.remove(ext);
    }

    public static String minifyPath(String path) {
        if (!minifyPathEnabled) {
            return path;
        }

        String suffix = getSuffix(path);
        if (!minifyCounters.containsKey(suffix)) {
            return path;
        }

        boolean isBuildPath = buildDirectory != null ? path.startsWith(buildDirectory) : false;
        if (isBuildPath) {
            path = path.substring(buildDirectory.length());
        }

        if (!path.startsWith("/"))
            path = "/" + path;

        String cachedPath = cachedPaths.getOrDefault(path, null);
        if (cachedPath != null) {
            return cachedPath;
        }

        Integer count = minifyCounters.getOrDefault(suffix, 0);
        minifyCounters.put(suffix, count + 1);
        int thousands = count / 1000;
        int remainder = count % 1000;

        String prefix = isBuildPath ? buildDirectory : "";
        String minifiedPath = String.format("%s/%d/%d%s", prefix, thousands, remainder, suffix);


        cachedPaths.put(path, minifiedPath);
        return minifiedPath;
    }

}
