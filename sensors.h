#pragma once 
#include <cmath>
#include <random>

struct Encoder{

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

struct Gyro{

    double bias= 0.02; 
    double noise_std = 0.002;
    double drift = 0.005;
    double last_time;
    std::mt19937 engine;
    std::normal_distribution<double> unit_normal{0.0, 1.0};

    explicit Gyro(double start_time, unsigned seed) : last_time(start_time), engine(seed) {}

    double read_speed (double now, double true_speed){

        double elapsed = now - last_time;
        if (elapsed > 0) {
            bias += drift* std::sqrt(elapsed) * unit_normal(engine); 
            last_time = now;
        }  
        
        double hiss = noise_std* unit_normal(engine);

        double reading = true_speed + bias + hiss;
        

        return reading; 
    }

};