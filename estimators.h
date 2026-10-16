#pragma once 
#include <cmath>
#include "sensors.h"

struct DiffEstimator{
    
    double last_time;
    int last_count; 

    explicit DiffEstimator(double start_time, int start_count) : last_time(start_time), last_count(start_count){}

    double update(double now, int count){
        double elapsed_time = now - last_time;
        if (elapsed_time >0){
            double speed = (count - last_count)*Encoder::size_one_count/elapsed_time;

            last_time = now;
            last_count = count; 

            return speed;
        }
        return 0.0;
    }

};