# Bound PS5 pipeline-build synchronization objects (backported from ProsperoEden).
# Keep the replacement ABI-compatible with headers seen outside video_core.
# Lichii moved the graphics pipeline's build wait into PipelineBuild (pipeline_build.h, one
# shared State per pipeline); the compute pipeline keeps its own members.
# A derived vk_graphics_pipeline.h from an earlier configure would shadow Lichii's header.
file(REMOVE "${PORT_BUILD_DIR}/pipeline-wait/video_core/renderer_vulkan/vk_graphics_pipeline.h")
foreach(pipeline_header IN ITEMS pipeline_build.h vk_compute_pipeline.h)
    file(READ "${PROJECT_SOURCE_DIR}/src/video_core/renderer_vulkan/${pipeline_header}" pipeline_source)
    if(pipeline_header STREQUAL "pipeline_build.h")
        set(pipeline_wait_old "        std::mutex mutex;\n        std::condition_variable condition;\n")
        set(pipeline_wait_new "        ::Eden::StripedMutex mutex;\n        ::Eden::StripedCondition condition;\n")
    else()
        set(pipeline_wait_old "    std::condition_variable build_condvar;\n    std::mutex build_mutex;\n")
        set(pipeline_wait_new "    ::Eden::StripedCondition build_condvar;\n    ::Eden::StripedMutex build_mutex;\n")
    endif()
    string(FIND "${pipeline_source}" "${pipeline_wait_old}" pipeline_wait_at)
    if(pipeline_wait_at LESS 0)
        message(FATAL_ERROR "Pinned ${pipeline_header} build wait changed")
    endif()
    string(REPLACE "${pipeline_wait_old}" "${pipeline_wait_new}" pipeline_source "${pipeline_source}")
    string(PREPEND pipeline_source "#include \"${EDEN_PORT_DIR}/striped_wait.h\"\n")
    write_derived("${PORT_BUILD_DIR}/pipeline-wait/video_core/renderer_vulkan/${pipeline_header}"
        "${pipeline_source}")
endforeach()
target_include_directories(video_core BEFORE PRIVATE "${PORT_BUILD_DIR}/pipeline-wait")
