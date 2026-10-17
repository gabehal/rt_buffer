#pragma once

struct PDController{
    double kp = 900;
    double kd = 6; 

    double torque(double target, double angle, double speed, double target_speed = 0.0) const {

        double torque_cmd = kp*(target - angle) + kd*(target_speed - speed);

        return  torque_cmd;
    }

};