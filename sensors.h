#pragma once 
#include <cmath>

struct Sensors{

    static constexpr double pi = 3.14159265358979323846; // static means one shared copy across all instances
    static constexpr int counts_per_rev = 4096; // constexpr means value knows at build time
    static constexpr double size_one_count = 2*pi/counts_per_rev; //one count size in radians

    int angle_to_counts (double angle) const {

        int counts = static_cast<int>(std::floor(angle/size_one_count));

        return counts;
    }

    double counts_to_angle (int counts) const {
        double angle = size_one_count * (counts + 0.5);

        return angle;
    }
};